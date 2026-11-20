import Foundation
import GRDB

/// Decides existing proposals atomically; accepting content prepares Git outside the write lock.
package struct DocTriageService {
  let environment: SiltaEnvironment
  var workspace: String?
  var approved: String?

  package init(environment: SiltaEnvironment, workspace: String? = nil, approved: String? = nil) {
    self.environment = environment
    self.workspace = workspace
    self.approved = approved
  }

  package func authorize(_ batch: DocTriage) throws -> HumanApproval? {
    let approval: HumanApproval?
    do {
      approval = try environment.actor.requireHuman(command: command(batch), approved: approved)
    } catch let error as ActorError {
      let safe =
        batch.refs.allSatisfy(DocService.safeReference)
        && (workspace.map { SecretGuard.matches(in: $0).isEmpty } ?? true)
      throw CommandFailure(
        error: error,
        next: safe ? [command(batch) + " --approved \"<the human's words>\""] : [hub],
        nextBy: safe ? .human : .agent)
    }
    do {
      guard !batch.refs.isEmpty, Set(batch.refs).count == batch.refs.count else {
        throw DocError.invalid("Choose each proposal exactly once with --accept or --reject.")
      }
      for ref in batch.refs { _ = try DocTriage.selection(ref) }
    } catch let error as DocError {
      throw CommandFailure(error: error, next: ["silta doc triage --help"], nextBy: .agent)
    }
    return approval
  }

  private func reject(_ batch: DocTriage) throws -> DocTriageResult {
    let approval = try authorize(batch)
    if !FileManager.default.fileExists(atPath: environment.db.path) {
      _ = try WorkspaceSelection.resolve(
        workspace, in: environment.db,
        prepared: environment.workspaceSelection)
    }
    var first: (slug: String, uid: String)?
    do {
      return try environment.db.write { tx in
        let slug = try WorkspaceSelection.resolve(
          workspace, in: tx.database,
          prepared: environment.workspaceSelection)
        let id = try TaskService.workspaceID(slug, in: tx.database)
        guard
          let uid = try String.fetchOne(
            tx.database,
            sql: "SELECT uid FROM workspace WHERE id=?", arguments: [id])
        else { throw StorageError.corrupt }
        if let first {
          guard first.slug.utf8.elementsEqual(slug.utf8), first.uid == uid else {
            throw DocError.changed(workspace: first.slug)
          }
        }
        first = (slug, uid)
        let members = try batch.reject.map {
          try DocStore.pending($0, workspace: id, in: tx.database)
        }
        let at = environment.clock.now()
        let store = DocStore(
          workspace: id, transaction: tx, actor: environment.actor,
          ids: environment.ids, at: at)
        for member in members { try store.reject(member) }
        try approval?.record(
          command: SecretGuard.redacted(workspaceCommand(batch.command, workspace: slug)),
          workspace: slug, identity: (environment.ids, at), in: tx)
        return DocTriageResult(
          docs: batch.reject.map {
            DocDecision(ref: SecretGuard.redacted($0), state: "rejected")
          }, workspace: slug,
          warnings: environment.actor.approvalWarnings(approved, used: approval != nil),
          approvalUsed: approval != nil)
      }
    } catch let error as any CodedError {
      throw recovery(error, batch: batch, selected: first?.slug)
    }
  }

  private func recovery(_ error: any CodedError, batch: DocTriage, selected: String?)
    -> any CodedError
  {
    if [.env, .busy].contains(error.code) { return error }
    if let selection = error as? WorkspaceError {
      let safe = selection.next.allSatisfy(DocService.safeReference)
      return CommandFailure(
        error: selection, next: safe ? selection.next : ["silta ws ls"],
        nextBy: safe ? selection.nextBy : .agent, message: SecretGuard.redacted(selection.message))
    }
    let read = (selected ?? workspace).map { DocService(workspace: $0, store: environment.db) }
    var next = read.map { read in batch.refs.map { read.showCommand($0) } } ?? [hub]
    let reproposals: [String]
    if let docError = error as? DocError, case .stale(let ref) = docError {
      reproposals = [ref]
      if let read, let selected = try? DocTriage.selection(ref) {  // Keep pinned reads.
        next.append(read.showCommand("doc:" + selected.0, flags: " --json"))
      }
    } else {
      reproposals = error.code == .conflict ? batch.accept : []
    }
    if let read {
      next += reproposals.map { ref in
        guard let selected = try? DocTriage.selection(ref),  // Invalid refs use the read hub.
          read.scopeIsSafe, DocService.safeReference(ref)
        else { return hub }
        return workspaceCommand(
          "silta doc propose " + shellWord("doc:" + selected.0)
            + " -F <file> -m <why> --base <rev> --title <title> --about <ref>",
          workspace: read.workspace)
      }
    }
    var seen: Set<String> = []
    return CommandFailure(
      error: error, next: next.filter { seen.insert($0).inserted }, nextBy: .agent,
      message: SecretGuard.redacted(error.message))
  }

  private var hub: String {
    workspace.map { DocService(workspace: $0, store: environment.db).listCommand } ?? "silta ws ls"
  }

  private func command(_ batch: DocTriage) -> String {
    guard batch.refs.allSatisfy(DocService.safeReference),
      workspace.map({ SecretGuard.matches(in: $0).isEmpty }) ?? true
    else { return hub }
    return workspace.map { workspaceCommand(batch.command, workspace: $0) } ?? batch.command
  }
}

extension DocTriageService {
  package func triage(_ batch: DocTriage) async throws -> DocTriageResult {
    if batch.accept.isEmpty { return try reject(batch) }
    let approval = try authorize(batch)
    var selected = self
    do {
      selected.workspace = try WorkspaceSelection.resolve(
        workspace, in: environment.db,
        prepared: environment.workspaceSelection)
      let captured = try environment.db.read { try selected.members(batch, in: $0) }
      var evidence: [DocVerification] = []
      for member in captured {
        if let binding = member.binding {
          evidence.append(try await DocVerification.prepare(binding, environment: environment))
        }
      }
      return try selected.accept(
        batch, captured: captured, evidence: evidence,
        approval: approval, originalWorkspace: workspace)
    } catch let error as any CodedError {
      throw selected.recovery(error, batch: batch, selected: selected.workspace)
    }
  }

  private func members(_ batch: DocTriage, in db: Database) throws -> [DocTriageMember] {
    let slug = try WorkspaceSelection.resolve(
      workspace, in: db,
      prepared: environment.workspaceSelection)
    let id = try TaskService.workspaceID(slug, in: db)
    var accepted: Set<Int64> = []
    return try batch.refs.enumerated().map { index, ref in
      let member = try DocTriageMember.read(
        ref, accept: index < batch.accept.count,
        workspace: id, in: db)
      if member.binding != nil, !accepted.insert(member.raw["doc_id"]).inserted {
        throw DocError.overlap(batch.accept)
      }
      return member
    }
  }

  private func accept(
    _ batch: DocTriage, captured: [DocTriageMember],
    evidence: [DocVerification], approval: HumanApproval?, originalWorkspace: String?
  )
    throws -> DocTriageResult
  {
    guard let workspace else { throw StorageError.internalMisuse }
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let current: [DocTriageMember]
      do {
        guard
          try WorkspaceSelection.resolve(
            originalWorkspace, in: tx.database,
            prepared: environment.workspaceSelection
          ).utf8.elementsEqual(workspace.utf8)
        else {
          throw DocError.changed(workspace: workspace)
        }
        current = try members(batch, in: tx.database)
      } catch let error as any CodedError
        where ![.env, .busy].contains(error.code)
      {
        throw DocError.changed(workspace: workspace)
      }
      guard zip(current, captured).allSatisfy({ $0.same(as: $1) }),
        zip(evidence, current.compactMap(\.binding)).allSatisfy({ $0.matches($1) })
      else { throw DocError.changed(workspace: workspace) }
      let id = try TaskService.workspaceID(workspace, in: tx.database)
      let store = DocStore(
        workspace: id, transaction: tx, actor: environment.actor,
        ids: environment.ids, at: at)
      for (index, member) in current.enumerated() {
        if index < batch.accept.count {
          try store.acceptProposal(member, verification: evidence[index])
        } else {
          try store.reject(member.raw)
        }
      }
      try approval?.record(
        command: SecretGuard.redacted(workspaceCommand(batch.command, workspace: workspace)),
        workspace: workspace, identity: (environment.ids, at), in: tx)
      return DocTriageResult(
        docs: current.map {
          DocDecision(
            ref: SecretGuard.redacted($0.ref),
            state: $0.binding == nil ? "rejected" : "accepted")
        }, workspace: workspace,
        warnings: environment.actor.approvalWarnings(approved, used: approval != nil),
        approvalUsed: approval != nil)
    }
  }
}
