import Foundation
import GRDB

struct DocEditRequest {
  var slug: String
  var title: String?
  var kind: String?
  var about: [String]?
  var allowSecret = false
  var keepBody = false
}

struct DocWriteResult {
  let ref: String
  let warnings: [OutputWarning]
}

/// Accepts explicit human-authorized edits without exposing owned bodies to callers.
struct DocWriteService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  func authorizeEdit(_ request: DocEditRequest) throws -> HumanApproval? {
    let command = command(request, workspace: workspace)
    do {
      return try environment.actor.requireHuman(command: command, approved: approved)
    } catch let error as any CodedError {
      if !safeScopeAndIdentity(request, workspace: workspace) {
        throw CommandFailure(
          error: error, next: [readCommand(workspace: workspace)], nextBy: .agent)
      }
      throw error
    }
  }

  func edit(_ request: DocEditRequest, input: (() throws -> String)?) async throws -> DocWriteResult
  {
    _ = try authorizeEdit(request)
    guard request.keepBody == (input == nil) else {
      throw CommandFailure(
        error: UsageError.usage(
          message: "Supply either input or --keep-body.",
          command: "silta doc show"), next: [readCommand(workspace: workspace)])
    }
    let slug = try WorkspaceSelection.resolve(
      workspace, in: environment.db,
      prepared: environment.workspaceSelection)
    var selected = self
    selected.workspace = slug
    do { return try await selected.save(request, input: input, workspace: slug) } catch let error
      as any CodedError
    {
      guard !safeScopeAndIdentity(request, workspace: slug) else { throw error }
      throw CommandFailure(error: error, next: [readCommand(workspace: slug)], nextBy: .agent)
    }
  }

  private func save(
    _ request: DocEditRequest, input: (() throws -> String)?, workspace slug: String
  )
    async throws -> DocWriteResult
  {
    let captured = try capture(request, workspace: slug)
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
        captured.baseline.matches(
          try DocEditBaseline.read(
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
      return DocWriteResult(
        ref: SecretGuard.redacted("doc:\(request.slug)@\(revision.revision)"), warnings: warnings)
    }
  }

  private func capture(_ request: DocEditRequest, workspace slug: String) throws
    -> CapturedEdit
  {
    return try environment.db.read { db in
      let id = try TaskService.workspaceID(slug, in: db)
      let baseline = try DocEditBaseline.read(
        request.slug, workspace: id, keepBody: request.keepBody, in: db)
      if request.keepBody && (!baseline.accepted || baseline.body == nil) {
        throw DocError.missing(["-F", "--title", "--about"])
      }
      if !baseline.accepted {
        try checkIdentity("doc:" + request.slug, request: request, workspace: slug)
      }
      for ref in request.about ?? []
      where !baseline.accepted
        || !baseline.refs.contains(where: { $0.utf8.elementsEqual(ref.utf8) })
      {
        try checkIdentity(ref.removingPercentEncoding ?? ref, request: request, workspace: slug)
      }
      var draft = DocDraft(slug: request.slug, body: "")
      draft.title = request.title
      draft.kind = request.kind
      draft.about = request.about
      _ = try DocMetadata.resolve(draft, workspace: id, in: db)
      var redacted = false
      if let title = draft.title,
        !baseline.accepted || !title.utf8.elementsEqual((baseline.title ?? "").utf8)
      {
        let checked = try checked(title, request: request, workspace: slug)
        draft.title = checked.0
        redacted = checked.1
      }
      let metadata = try DocMetadata.resolve(draft, workspace: id, in: db)
      return CapturedEdit(
        id: id, baseline: baseline, draft: draft,
        binding: try DocVerification.binding(metadata, workspace: id, in: db), redacted: redacted)
    }
  }

  private struct CapturedEdit {
    let id: Int64
    let baseline: DocEditBaseline
    let draft: DocDraft
    let binding: DocVerification.Binding
    let redacted: Bool
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
      unchanged ? (text, false) : try checked(text, request: request, workspace: workspace)
    try DocInput.check(value.0)
    return value
  }

  private func checkIdentity(_ text: String, request: DocEditRequest, workspace: String) throws {
    if !request.allowSecret, !SecretGuard.matches(in: text).isEmpty {
      throw secretFailure(text, request: request, workspace: workspace)
    }
  }

  private func checked(_ text: String, request: DocEditRequest, workspace: String) throws -> (
    String, Bool
  ) {
    guard !request.allowSecret, !SecretGuard.matches(in: text).isEmpty else { return (text, false) }
    if environment.actor.isHuman {
      throw secretFailure(text, request: request, workspace: workspace)
    }
    return (SecretGuard.redacted(text), true)
  }

  private func secretFailure(_ text: String, request: DocEditRequest, workspace: String)
    -> any CodedError
  {
    let error = SecretError(command: command(request, workspace: workspace), text: text)
    return safeScopeAndIdentity(request, workspace: workspace)
      ? error
      : CommandFailure(error: error, next: [readCommand(workspace: workspace)], nextBy: .agent)
  }

  private func safeScopeAndIdentity(_ request: DocEditRequest, workspace: String?) -> Bool {
    (workspace.map { SecretGuard.matches(in: $0).isEmpty } ?? true)
      && DocService.safeReference("doc:" + request.slug)
  }

  private func readCommand(workspace: String?) -> String {
    guard let workspace else { return "silta ws ls" }
    return DocService(workspace: workspace, store: environment.db).listCommand
  }

  private func auditCommand(_ request: DocEditRequest, workspace: String) -> String {
    SecretGuard.redacted(
      workspaceCommand("silta doc edit " + shellWord(request.slug), workspace: workspace))
      + (request.keepBody ? " --keep-body" : " -F <file>")
      + (request.title == nil ? "" : " --title <title>")
      + (request.kind == nil ? "" : " --kind <kind>")
      + (request.about == nil ? "" : " --about <ref>")
      + (request.allowSecret ? " --allow-secret" : "")
  }

  private func command(_ request: DocEditRequest, workspace: String?) -> String {
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return readCommand(workspace: workspace)
    }
    let base =
      "silta doc edit " + shellWord(request.slug)
      + (request.keepBody ? " --keep-body" : " -F <file>")
      + (request.title == nil ? "" : " --title <title>")
      + (request.kind == nil ? "" : " --kind <kind>")
      + (request.about == nil ? "" : " --about <ref>")
      + (request.allowSecret ? " --allow-secret" : "")
    return workspace.map { workspaceCommand(base, workspace: $0) } ?? base
  }
}
