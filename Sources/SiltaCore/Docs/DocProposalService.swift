import Foundation
import GRDB

/// Captures supplied document knowledge without accepting it or invoking Git.
package struct DocProposalService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  /// Uses command-scoped seams and optional workspace selection.
  package init(environment: SiltaEnvironment, workspace: String? = nil, approved: String? = nil) {
    self.environment = environment
    self.workspace = workspace
    self.approved = approved
  }

  /// Reads the supplied body before resolving database state in one owned write.
  package func propose(_ request: DocProposalRequest, input: (() throws -> String)?) throws
    -> DocProposalResult
  {
    var selected = self
    do {
      var missing = input == nil ? ["-F"] : []
      if request.why == nil { missing.append("-m") }
      guard missing.isEmpty, let input else { throw DocError.missing(missing) }
      let supplied = try input()
      try DocInput.check(supplied)
      guard !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DocError.invalid("A proposal body must not be blank.")
      }
      if !FileManager.default.fileExists(atPath: environment.db.path) {
        _ = try WorkspaceSelection.resolve(
          workspace, in: environment.db, prepared: environment.workspaceSelection)
      }
      return try environment.db.write { tx in
        let workspace = try WorkspaceSelection.resolve(
          self.workspace, in: tx.database, prepared: environment.workspaceSelection)
        selected.workspace = workspace
        let at = environment.clock.now()
        let prepared = try selected.capture(
          request, workspace: workspace, at: at, in: tx.database)
        let body = try selected.policy.checked(supplied, keeping: prepared.baseline.body)
        try DocInput.check(body.0)
        var draft = DocDraft(slug: request.slug, body: body.0)
        draft.message = prepared.why
        let revision = try DocStore(
          workspace: prepared.id, transaction: tx, actor: environment.actor,
          ids: environment.ids, at: at
        ).propose(draft, metadata: prepared.metadata, base: prepared.base, source: prepared.source)
        return DocProposalResult(
          ref: SecretGuard.redacted("doc:\(request.slug)@\(revision.revision)"),
          warnings: environment.actor.approvalWarnings(approved, used: false)
            + (prepared.redacted || body.1 ? [SecretGuard.warning] : []), workspace: workspace)
      }
    } catch let error as any CodedError {
      throw selected.recovery(error, request: request)
    }
  }

  private struct Prepared {
    let id: Int64
    let baseline: DocEditBaseline
    let metadata: DocMetadata
    let base: Int?
    let source: Int64?
    let why: String
    let redacted: Bool
  }

  private func capture(
    _ request: DocProposalRequest, workspace: String, at: Date, in db: Database
  ) throws -> Prepared {
    guard WorkspaceConfig.isValidIdentifier(request.slug) else {
      throw DocError.invalid("Use an identifier for the doc slug.")
    }
    let id = try TaskService.workspaceID(workspace, in: db)
    let baseline = try DocEditBaseline.read(request.slug, workspace: id, keepBody: false, in: db)
    if baseline.revision != nil && !baseline.accepted { throw StorageError.corrupt }
    let why = try requiredWhy(request, accepted: baseline.accepted)
    if !baseline.accepted { try policy.identity("doc:" + request.slug) }
    for ref in request.about ?? []
    where !baseline.accepted
      || !baseline.refs.contains(where: { $0.utf8.elementsEqual(ref.utf8) })
    {
      try policy.identity(ref.removingPercentEncoding ?? ref)
    }
    var safe = request
    var redacted = false
    if let title = request.title {
      let value = try policy.title(title, keeping: baseline.accepted ? baseline.title : nil)
      safe.title = value.0
      redacted = value.1
    }
    var draft = DocDraft(slug: safe.slug, body: "")
    draft.title = safe.title
    draft.about = safe.about
    let metadata = try DocMetadata.resolve(
      draft, baseline: baseline, workspace: id, in: db)
    let reason = try policy.checked(why)
    let base = try acceptedBase(request, baseline: baseline, workspace: id, in: db)
    return try Prepared(
      id: id, baseline: baseline, metadata: metadata, base: base,
      source: source(request, workspace: workspace, id: id, at: at, in: db),
      why: reason.0, redacted: redacted || reason.1)
  }

  private func acceptedBase(
    _ request: DocProposalRequest, baseline: DocEditBaseline, workspace id: Int64, in db: Database
  ) throws -> Int? {
    let base: Int?
    if let supplied = request.base {
      if let number = Int(supplied), number > 0 {
        base = number
      } else {
        let (slug, number) = try DocTriage.selection(supplied)
        guard slug == request.slug else {
          throw DocError.invalid("--base must name an accepted revision of this doc.")
        }
        base = number
      }
    } else {
      base = baseline.accepted ? baseline.revision : nil
    }
    if let base {
      guard
        let state = try String.fetchOne(
          db,
          sql: """
            SELECT r.state FROM doc_rev r JOIN doc d ON d.id=r.doc_id
            WHERE d.workspace_id=? AND d.slug=? AND r.rev=?
            """, arguments: [id, request.slug, base])
      else { throw DocError.notFound(request.slug + "@\(base)") }
      guard state == "accepted" else {
        throw DocError.invalid("--base must name an accepted revision of this doc.")
      }
    }
    return base
  }

  private func requiredWhy(_ request: DocProposalRequest, accepted: Bool) throws
    -> String
  {
    var missing: [String] = []
    if request.why == nil { missing.append("-m") }
    if !accepted {
      if request.title == nil { missing.append("--title") }
      if request.about == nil { missing.append("--about") }
    }
    guard missing.isEmpty, let why = request.why else { throw DocError.missing(missing) }
    return why
  }

  private var policy: DocInputPolicy {
    DocInputPolicy(actor: environment.actor, allowSecret: false, command: "silta doc propose")
  }
}
