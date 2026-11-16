import Foundation
import GRDB

/// Decides existing proposals atomically, with acceptance Git work outside the write lock.
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
        batch.accept.allSatisfy(DocService.safeReference)
        && batch.reject.allSatisfy(DocService.safeReference)
        && (workspace.map { SecretGuard.matches(in: $0).isEmpty } ?? true)
      throw CommandFailure(
        error: error,
        next: safe ? [command(batch) + " --approved \"<the human's words>\""] : [hub],
        nextBy: safe ? .human : .agent)
    }
    do {
      let refs = batch.accept + batch.reject
      guard !refs.isEmpty, Set(refs).count == refs.count else {
        throw DocError.invalid("Choose each proposal exactly once with --accept or --reject.")
      }
      for ref in refs { _ = try DocTriageMember.selection(ref) }
    } catch let error as DocError {
      throw CommandFailure(error: error, next: ["silta doc triage --help"], nextBy: .agent)
    }
    return approval
  }

  package func triage(_ batch: DocTriage) async throws -> DocTriageResult {
    _ = try authorize(batch)
    var selected = self
    do {
      selected.workspace = try WorkspaceSelection.resolve(
        workspace, in: environment.db,
        prepared: environment.workspaceSelection)
      let captured =
        batch.accept.isEmpty
        ? nil
        : try environment.db.read {
          try selected.read(batch, in: $0)
        }
      var evidence: [DocVerification] = []
      for member in captured ?? [] {
        if let binding = member.binding {
          evidence.append(try await DocVerification.prepare(binding, environment: environment))
        }
      }
      return try selected.commit(
        batch, captured: captured, evidence: evidence, originalWorkspace: workspace)
    } catch let error as any CodedError {
      if [.env, .busy].contains(error.code) { throw error }
      if let selection = error as? WorkspaceError {
        let safe = selection.next.allSatisfy(DocService.safeReference)
        throw CommandFailure(
          error: selection, next: safe ? selection.next : ["silta ws ls"],
          nextBy: safe ? selection.nextBy : .agent, message: SecretGuard.redacted(selection.message)
        )
      }
      var next = [selected.hub]
      if let workspace = selected.workspace {
        let read = DocService(workspace: workspace, store: environment.db)
        next = (batch.accept + batch.reject).map { read.showCommand($0, flags: " --diff") }
        if [.staleRev, .conflict].contains(error.code) {
          next += batch.accept.map { ref in
            guard let target = try? DocTriageMember.selection(ref),  // Invalid refs use the hub.
              read.scopeIsSafe, DocService.safeReference(ref)
            else { return selected.hub }
            return workspaceCommand(
              "silta doc propose " + shellWord("doc:" + target.0)
                + " -F <file> -m <why> --base <rev> --title <title> --about <ref>",
              workspace: workspace)
          }
        }
      }
      throw CommandFailure(
        error: error, next: next.isEmpty ? [selected.hub] : next,
        nextBy: .agent, message: SecretGuard.redacted(error.message))
    }
  }

  func read(_ batch: DocTriage, in db: Database) throws -> [DocTriageMember] {
    let slug = try WorkspaceSelection.resolve(
      workspace, in: db, prepared: environment.workspaceSelection)
    let id = try TaskService.workspaceID(slug, in: db)
    var accepted: Set<Int64> = []
    return try (batch.accept + batch.reject).enumerated().map { index, ref in
      let member = try DocTriageMember.read(
        ref, accept: index < batch.accept.count,
        workspace: id, in: db)
      if member.binding != nil, !accepted.insert(member.raw["doc_id"]).inserted {
        throw DocError.overlap(batch.accept)
      }
      return member
    }
  }

  private func commit(
    _ batch: DocTriage, captured: [DocTriageMember]?, evidence: [DocVerification],
    originalWorkspace: String?
  )
    throws -> DocTriageResult
  {
    guard let workspace else { throw StorageError.internalMisuse }
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let approval = try authorize(batch)
      let members: [DocTriageMember]
      do {
        guard
          try WorkspaceSelection.resolve(
            originalWorkspace, in: tx.database,
            prepared: environment.workspaceSelection) == workspace
        else {
          throw DocError.changed(workspace: workspace)
        }
        members = try read(batch, in: tx.database)
      } catch let error as any CodedError
        where captured != nil && ![.env, .busy].contains(error.code)
      {
        throw DocError.changed(workspace: workspace)
      }
      if let captured {
        guard members.count == captured.count,
          zip(members, captured).allSatisfy({ $0.same(as: $1) }),
          zip(evidence, members.compactMap(\.binding)).allSatisfy({ $0.matches($1) })
        else { throw DocError.changed(workspace: workspace) }
      }
      let id = try TaskService.workspaceID(workspace, in: tx.database)
      let store = DocStore(
        workspace: id, transaction: tx, actor: environment.actor,
        ids: environment.ids, at: at)
      for (index, member) in members.enumerated() {
        try store.decide(member, verification: index < evidence.count ? evidence[index] : nil)
      }
      try approval?.record(
        command: SecretGuard.redacted(workspaceCommand(batch.command, workspace: workspace)),
        workspace: workspace, identity: (environment.ids, at), in: tx)
      return DocTriageResult(
        docs: members.map {
          DocDecision(
            ref: SecretGuard.redacted($0.ref), state: $0.binding == nil ? "rejected" : "accepted")
        }, workspace: workspace,
        warnings: environment.actor.approvalWarnings(approved, used: approval != nil),
        approvalUsed: approval != nil)
    }
  }

  private var hub: String {
    workspace.map { DocService(workspace: $0, store: environment.db).listCommand } ?? "silta ws ls"
  }

  private func command(_ batch: DocTriage) -> String {
    guard batch.accept.allSatisfy(DocService.safeReference),
      batch.reject.allSatisfy(DocService.safeReference),
      workspace.map({ SecretGuard.matches(in: $0).isEmpty }) ?? true
    else { return hub }
    return workspace.map { workspaceCommand(batch.command, workspace: $0) } ?? batch.command
  }
}
