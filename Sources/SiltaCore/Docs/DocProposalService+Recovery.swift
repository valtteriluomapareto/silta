extension DocProposalService {
  func recovery(_ error: any CodedError, request: DocProposalRequest) -> any CodedError {
    if error is StorageError { return error }
    if error.code == .env, error.next == ["silta backup"] { return error }
    let message = SecretGuard.redacted(error.message)
    if let selection = error as? WorkspaceError {
      let safe = selection.next.allSatisfy(DocService.recoveryIsSafe)
      return CommandFailure(
        error: selection, next: safe ? selection.next : ["silta ws ls"],
        nextBy: safe ? selection.nextBy : .agent, message: message)
    }
    let hub =
      workspace.map { DocService(workspace: $0, store: environment.db).listCommand }
      ?? "silta ws ls"
    guard let workspace, DocService.identifierIsSafe(workspace),
      DocService.referenceIsSafe("doc:" + request.slug)
    else {
      return CommandFailure(error: error, next: [hub], nextBy: .agent, message: message)
    }
    var fields: [String] = []
    if case .missing(let missing) = error as? DocError { fields = missing }
    var retry = "silta doc propose " + shellWord("doc:" + request.slug) + " -F <file> -m <why>"
    if request.title != nil || fields.contains("--title") { retry += " --title <title>" }
    if request.about != nil || fields.contains("--about") { retry += " --about <ref>" }
    if request.base != nil { retry += " --base <rev>" }
    if request.task != nil || fields.contains("--task") { retry += " --task <ref>" }
    let read = DocService(workspace: workspace, store: environment.db)
    let scopedRetry = workspaceCommand(retry, workspace: workspace)
    let next: [String]
    let owner: NextBy
    if let preparation = error as? CommandFailure {
      next = preparation.next + [scopedRetry]
      owner = preparation.nextBy
    } else {
      next =
        error.code == .notFound || error.code == .conflict || request.base != nil
        ? [read.showCommand("doc:" + request.slug), scopedRetry] : [scopedRetry]
      owner = .agent
    }
    return CommandFailure(error: error, next: next, nextBy: owner, message: message)
  }
}
