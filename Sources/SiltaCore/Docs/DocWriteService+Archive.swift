import Foundation

extension DocWriteService {
  /// Checks the human gate without selection or storage I/O.
  package func authorizeArchive(_ ref: String) throws -> HumanApproval? {
    let request = DocEditRequest(slug: ref)
    do {
      return try environment.actor.requireHuman(
        command: archiveCommand(request, workspace: workspace), approved: approved)
    } catch let error as any CodedError {
      if !safeScopeAndIdentity(request, workspace: workspace) {
        throw CommandFailure(
          error: error, next: [readCommand(workspace: workspace)], nextBy: .agent)
      }
      if case .invalidApproval? = error as? ActorError {
        throw CommandFailure(
          error: error,
          next: [
            archiveCommand(request, workspace: workspace)
              + " --approved \"<the human's words>\""
          ], nextBy: .human)
      }
      throw error
    }
  }

  /// Removes live attachments without Git or a revision; a true no-op stores no approval.
  package func archive(_ ref: String) throws -> DocWriteResult {
    _ = try authorizeArchive(ref)
    let request = DocEditRequest(slug: ref)
    guard WorkspaceConfig.isValidIdentifier(request.slug) else {
      throw UsageError.usage(
        message: "Use a doc slug or doc:slug without a revision.", command: "silta doc archive")
    }
    let slug = try WorkspaceSelection.resolve(
      workspace, in: environment.db,
      prepared: environment.workspaceSelection)
    let at = environment.clock.now()
    do {
      return try environment.db.write { tx in
        let command = archiveCommand(request, workspace: slug)
        let approval = try environment.actor.requireHuman(command: command, approved: approved)
        let id = try TaskService.workspaceID(slug, in: tx.database)
        let changed = try DocStore(
          workspace: id, transaction: tx, actor: environment.actor,
          ids: environment.ids, at: at
        ).archive(request.slug)
        if changed {
          let audit = workspaceCommand(
            "silta doc archive " + shellWord("doc:" + request.slug), workspace: slug)
          try approval?.record(
            command: SecretGuard.redacted(audit), workspace: slug,
            identity: (environment.ids, at), in: tx)
        }
        let used = changed && approval != nil
        return DocWriteResult(
          ref: SecretGuard.redacted("doc:" + request.slug),
          warnings: environment.actor.approvalWarnings(approved, used: used),
          workspace: slug, approvalUsed: used, archived: true, changed: changed)
      }
    } catch let error as DocError {
      let shown: any CodedError
      if case .notFound = error {
        shown = DocError.notFound("doc:" + request.slug)
      } else {
        shown = error
      }
      throw CommandFailure(error: shown, next: [readCommand(workspace: slug)], nextBy: .agent)
    }
  }

  private func archiveCommand(_ request: DocEditRequest, workspace: String?) -> String {
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return readCommand(workspace: workspace)
    }
    let command = "silta doc archive " + shellWord("doc:" + request.slug)
    return workspace.map { workspaceCommand(command, workspace: $0) } ?? command
  }
}
