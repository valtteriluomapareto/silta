import Foundation
import GRDB

/// Rejects existing proposals atomically without reading their retained content or running Git.
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
        batch.reject.allSatisfy(DocService.safeReference)
        && (workspace.map { SecretGuard.matches(in: $0).isEmpty } ?? true)
      throw CommandFailure(
        error: error,
        next: safe ? [command(batch) + " --approved \"<the human's words>\""] : [hub],
        nextBy: safe ? .human : .agent)
    }
    do {
      guard !batch.reject.isEmpty, Set(batch.reject).count == batch.reject.count else {
        throw DocError.invalid("Choose each proposal exactly once with --reject.")
      }
      for ref in batch.reject { _ = try DocTriage.selection(ref) }
    } catch let error as DocError {
      throw CommandFailure(error: error, next: ["silta doc triage --help"], nextBy: .agent)
    }
    return approval
  }

  package func triage(_ batch: DocTriage) throws -> DocTriageResult {
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
          let uid = try StoredUID.fetch(
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
    return CommandFailure(
      error: error,
      next: read.map { read in batch.reject.map { read.showCommand($0) } } ?? [hub],
      nextBy: .agent, message: SecretGuard.redacted(error.message))
  }

  private var hub: String {
    workspace.map { DocService(workspace: $0, store: environment.db).listCommand } ?? "silta ws ls"
  }

  private func command(_ batch: DocTriage) -> String {
    guard batch.reject.allSatisfy(DocService.safeReference),
      workspace.map({ SecretGuard.matches(in: $0).isEmpty }) ?? true
    else { return hub }
    return workspace.map { workspaceCommand(batch.command, workspace: $0) } ?? batch.command
  }
}
