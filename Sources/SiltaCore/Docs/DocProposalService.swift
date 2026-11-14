import Foundation
import GRDB

/// Captures supplied document knowledge without accepting it or invoking Git.
struct DocProposalService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  func propose(_ request: DocProposalRequest, input: (() throws -> String)?) throws
    -> DocProposalResult
  {
    var selected = self
    do {
      selected.workspace = try WorkspaceSelection.resolve(
        workspace, in: environment.db, prepared: environment.workspaceSelection)
      return try selected.save(request, input: input)
    } catch let error as any CodedError {
      throw selected.recovery(error, request: request)
    }
  }

  private func save(_ request: DocProposalRequest, input: (() throws -> String)?) throws
    -> DocProposalResult
  {
    guard let workspace else { throw StorageError.internalMisuse }
    let at = environment.clock.now()
    let captured = try environment.db.read {
      try capture(request, hasInput: input != nil, workspace: workspace, at: at, in: $0)
    }
    guard let input else { throw DocError.missing(["-F"]) }
    let supplied = try input()
    try DocInput.check(supplied)
    let body = try checked(supplied, keeping: captured.baseline.body)
    try DocInput.check(body.0)
    return try environment.db.write { tx in
      guard
        captured.baseline.matches(
          try DocEditBaseline.read(
            request.slug, workspace: captured.id, keepBody: false, in: tx.database))
      else { throw DocError.changed(workspace: workspace) }
      do {
        let identity = try binding(
          captured.metadata, base: captured.base, request: request, id: captured.id, in: tx.database
        )
        let source = try source(
          request, workspace: workspace, id: captured.id, at: at, in: tx.database)
        guard Self.same(captured.identity, identity),
          Self.same(captured.source.fields, source.fields)
        else { throw DocError.changed(workspace: workspace) }
      } catch let error as any CodedError where !(error is StorageError) {
        throw DocError.changed(workspace: workspace)
      }
      var draft = DocDraft(slug: request.slug, body: body.0)
      draft.message = captured.why
      let revision = try DocStore(
        workspace: captured.id, transaction: tx, actor: environment.actor, ids: environment.ids,
        at: at
      ).propose(
        draft, metadata: captured.metadata, base: captured.base, source: captured.source.id)
      return DocProposalResult(
        ref: SecretGuard.redacted("doc:\(request.slug)@\(revision.revision)"),
        warnings: environment.actor.approvalWarnings(approved, used: false)
          + (captured.redacted || body.1 ? [SecretGuard.warning] : []), workspace: workspace)
    }
  }

  private struct Captured {
    let id: Int64
    let baseline: DocEditBaseline
    let metadata: DocMetadata
    let base: Int?
    let identity: [String?]
    let source: (id: Int64?, fields: [String?])
    let why: String
    let redacted: Bool
  }

  private func capture(
    _ request: DocProposalRequest, hasInput: Bool, workspace: String, at: Date, in db: Database
  ) throws -> Captured {
    let id = try TaskService.workspaceID(workspace, in: db)
    let baseline = try DocEditBaseline.read(request.slug, workspace: id, keepBody: false, in: db)
    if baseline.revision != nil && !baseline.accepted { throw StorageError.corrupt }
    let why = try requiredWhy(request, hasInput: hasInput, accepted: baseline.accepted)
    if !baseline.accepted { try identityCheck("doc:" + request.slug) }
    for ref in request.about ?? []
    where !baseline.accepted
      || !baseline.refs.contains(where: { $0.utf8.elementsEqual(ref.utf8) })
    {
      try identityCheck(ref.removingPercentEncoding ?? ref)
    }
    var safe = request
    var redacted = false
    if let title = request.title,
      !baseline.accepted || !title.utf8.elementsEqual((baseline.title ?? "").utf8)
    {
      try DocMetadata.checkTitle(title)
      let value = try checked(title)
      safe.title = value.0
      redacted = value.1
    }
    let metadata = try DocMetadata.proposal(safe, baseline: baseline, workspace: id, in: db)
    let reason = try checked(why)
    let base: Int?
    if let supplied = request.base {
      guard let number = Int(supplied), number > 0 else {
        throw DocError.invalid("--base must be a positive revision.")
      }
      base = number
    } else {
      base = baseline.accepted ? baseline.revision : nil
    }
    return try Captured(
      id: id, baseline: baseline, metadata: metadata, base: base,
      identity: binding(metadata, base: base, request: request, id: id, in: db),
      source: source(request, workspace: workspace, id: id, at: at, in: db),
      why: reason.0, redacted: redacted || reason.1)
  }

  private func requiredWhy(_ request: DocProposalRequest, hasInput: Bool, accepted: Bool) throws
    -> String
  {
    var missing = hasInput ? [] : ["-F"]
    if request.why == nil { missing.append("-m") }
    if !accepted {
      if request.title == nil { missing.append("--title") }
      if request.about == nil { missing.append("--about") }
    }
    guard missing.isEmpty, let why = request.why else { throw DocError.missing(missing) }
    return why
  }

  private func checked(_ text: String, keeping old: String? = nil) throws -> (String, Bool) {
    if old.map({ text.utf8.elementsEqual($0.utf8) }) == true
      || SecretGuard.matches(in: text).isEmpty
    {
      return (text, false)
    }
    if environment.actor.isHuman { throw SecretError(command: "silta doc propose", text: text) }
    return (SecretGuard.redacted(text), true)
  }

  private func identityCheck(_ text: String) throws {
    if !SecretGuard.matches(in: text).isEmpty {
      throw SecretError(command: "silta doc propose", text: text)
    }
  }

  static func same(_ left: [String?], _ right: [String?]) -> Bool {
    left.elementsEqual(right) { a, b in
      switch (a, b) {
      case (nil, nil): true
      case (let a?, let b?): a.utf8.elementsEqual(b.utf8)
      default: false
      }
    }
  }
}
