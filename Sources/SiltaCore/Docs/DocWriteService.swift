import Foundation
import GRDB

/// Accepts explicit human-authorized edits without exposing owned bodies to callers.
package struct DocWriteService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  /// Uses command-scoped dependencies and an explicit or captured workspace selection.
  package init(environment: SiltaEnvironment, workspace: String? = nil, approved: String? = nil) {
    self.environment = environment
    self.workspace = workspace
    self.approved = approved
  }

  /// Applies the human gate without input, selection or storage I/O.
  package func authorizeEdit(_ request: DocEditRequest) throws -> HumanApproval? {
    let command = command(request, workspace: workspace)
    do {
      return try environment.actor.requireHuman(command: command, approved: approved)
    } catch let error as any CodedError {
      if !safeScopeAndIdentity(request, workspace: workspace) {
        throw CommandFailure(
          error: error, next: [readCommand(workspace: workspace)], nextBy: .agent)
      }
      if case .invalidApproval? = error as? ActorError {
        throw CommandFailure(
          error: error, next: [retry(request, workspace: workspace)], nextBy: .human)
      }
      throw error
    }
  }

  /// Saves one accepted revision and its used approval atomically; Git runs before the write.
  package func edit(_ request: DocEditRequest, input: (() throws -> String)?) async throws
    -> DocWriteResult
  {
    _ = try authorizeEdit(request)
    guard !(request.keepBody && input != nil) else {
      throw CommandFailure(
        error: UsageError.usage(
          message: "Use exactly one of -F and --keep-body.",
          command: "silta doc edit"), next: [retry(request, workspace: workspace)])
    }
    let slug = try WorkspaceSelection.resolve(
      workspace, in: environment.db,
      prepared: environment.workspaceSelection)
    var selected = self
    selected.workspace = slug
    do { return try await selected.save(request, input: input, workspace: slug) } catch let error
      as any CodedError
    {
      throw recovery(error, request: request, workspace: slug)
    }
  }

  private func save(
    _ request: DocEditRequest, input: (() throws -> String)?, workspace slug: String
  )
    async throws -> DocWriteResult
  {
    let captured = try capture(request, hasInput: input != nil, workspace: slug)
    var draft = captured.draft
    let (body, bodyRedacted) = try suppliedBody(
      input, baseline: captured.baseline,
      request: request, workspace: slug)
    draft.body = body
    let verification = try await DocVerification.prepare(captured.binding, environment: environment)
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let approval = try authorizeEdit(request)
      guard
        captured.baseline
          == (try DocEditBaseline.read(
            request.slug, workspace: captured.id,
            keepBody: request.keepBody, in: tx.database))
      else { throw DocError.changed(workspace: slug) }
      let revision = try DocStore(
        workspace: captured.id, transaction: tx, actor: environment.actor,
        ids: environment.ids, at: at
      ).accept(draft, verification: verification)
      try approval?.record(
        command: auditCommand(request, workspace: slug),
        workspace: slug, identity: (environment.ids, at), in: tx)
      let warnings =
        environment.actor.approvalWarnings(approved, used: approval != nil)
        + (captured.redacted || bodyRedacted ? [SecretGuard.warning] : [])
        + captured.mapWarnings
      return DocWriteResult(
        ref: SecretGuard.redacted("doc:\(request.slug)@\(revision.revision)"), warnings: warnings,
        workspace: slug, approvalUsed: approval != nil)
    }
  }

  private func capture(_ request: DocEditRequest, hasInput: Bool, workspace slug: String) throws
    -> CapturedEdit
  {
    return try environment.db.read { db in
      let id = try TaskService.workspaceID(slug, in: db)
      let baseline = try DocEditBaseline.read(
        request.slug, workspace: id, keepBody: request.keepBody, in: db)
      if request.keepBody && (!baseline.accepted || baseline.body == nil) {
        throw DocError.missing(["-F", "--title", "--about"])
      }
      let policy = policy(request, workspace: slug)
      if !baseline.accepted {
        try policy.identity("doc:" + request.slug)
      }
      let retainedRefs = baseline.accepted ? baseline.refs : []
      try policy.identities(request.about ?? [], keeping: retainedRefs)
      var draft = DocDraft(slug: request.slug, body: "")
      draft.title = request.title
      draft.kind = request.kind
      draft.about = request.about
      do {
        _ = try DocMetadata.resolve(draft, baseline: baseline, workspace: id, in: db)
      } catch DocError.missing(
        let fields)
      {
        throw DocError.missing((!hasInput && !request.keepBody ? ["-F"] : []) + fields)
      }
      if !hasInput && !request.keepBody {
        throw UsageError.usage(message: "Supply -F or --keep-body.", command: "silta doc edit")
      }
      var redacted = false
      if let title = draft.title {
        let checked = try policy.title(
          title, keeping: baseline.accepted ? baseline.title : nil)
        draft.title = checked.0
        redacted = checked.1
      }
      let metadata = try DocMetadata.resolve(draft, baseline: baseline, workspace: id, in: db)
      try policy.identities(metadata.refs, keeping: retainedRefs)
      let warnings = metadata.targets.flatMap(\.warnings).reduce(into: [OutputWarning]()) {
        if !$0.contains($1) { $0.append($1) }
      }
      return CapturedEdit(
        id: id, baseline: baseline, draft: draft,
        binding: try DocVerification.binding(metadata, workspace: id, in: db),
        redacted: redacted, mapWarnings: warnings)
    }
  }

  private struct CapturedEdit {
    let id: Int64
    let baseline: DocEditBaseline
    let draft: DocDraft
    let binding: DocVerification.Binding
    let redacted: Bool
    let mapWarnings: [OutputWarning]
  }

  private func suppliedBody(
    _ input: (() throws -> String)?, baseline: DocEditBaseline,
    request: DocEditRequest, workspace: String
  ) throws -> (String, Bool) {
    guard let input else {
      guard let body = baseline.body else { throw StorageError.internalMisuse }
      return (body, false)
    }
    let text = try input()
    try DocInput.check(text)
    let unchanged = baseline.body.map { text.utf8.elementsEqual($0.utf8) } ?? false
    let value =
      unchanged ? (text, false) : try policy(request, workspace: workspace).checked(text)
    try DocInput.check(value.0)
    return value
  }

  private func policy(_ request: DocEditRequest, workspace: String) -> DocInputPolicy {
    DocInputPolicy(
      actor: environment.actor, allowSecret: request.allowSecret,
      command: command(request, workspace: workspace))
  }

  func safeScopeAndIdentity(_ request: DocEditRequest, workspace: String?) -> Bool {
    guard workspace.map({ SecretGuard.matches(in: $0).isEmpty }) ?? true,
      DocService.safeReference("doc:" + request.slug)
    else { return false }
    guard request.retryFromStdin else { return true }
    let metadata = [request.title, request.kind].compactMap { $0 } + (request.about ?? [])
    let disallowed = CharacterSet.controlCharacters.union(.newlines)
    return metadata.allSatisfy {
      DocService.safeReference($0) && $0.rangeOfCharacter(from: disallowed) == nil
    }
  }

  func readCommand(workspace: String?) -> String {
    guard let workspace else { return "silta ws ls" }
    return DocService(workspace: workspace, store: environment.db).listCommand
  }

  private func auditCommand(_ request: DocEditRequest, workspace: String) -> String {
    SecretGuard.redacted(
      workspaceCommand("silta doc edit " + shellWord("doc:" + request.slug), workspace: workspace))
      + flags(request)
  }

  func command(_ request: DocEditRequest, workspace: String?) -> String {
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return readCommand(workspace: workspace)
    }
    let base =
      "silta doc edit " + shellWord("doc:" + request.slug)
      + flags(request, stdin: request.retryFromStdin)
    return workspace.map { workspaceCommand(base, workspace: $0) } ?? base
  }
  private func flags(_ request: DocEditRequest, stdin: Bool = false) -> String {
    let body = request.keepBody ? " --keep-body" : stdin ? " -F -" : " -F <file>"
    let title = request.title.map { stdin ? " --title=" + shellWord($0) : " --title <title>" } ?? ""
    let kind = request.kind.map { " --kind " + (stdin ? shellWord($0) : "<kind>") } ?? ""
    let about =
      request.about.map { refs in
        stdin ? refs.map { " --about " + shellWord($0) }.joined() : " --about <ref>"
      } ?? ""
    return body + title + kind + about + (request.allowSecret ? " --allow-secret" : "")
  }

}
