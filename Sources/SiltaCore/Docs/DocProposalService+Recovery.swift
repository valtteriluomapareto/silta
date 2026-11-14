extension DocProposalService {
  func recovery(_ error: any CodedError, request: DocProposalRequest) -> any CodedError {
    if error is StorageError { return error }
    let message = SecretGuard.redacted(error.message)
    if let selection = error as? WorkspaceError {
      let safe = selection.next.allSatisfy(DocService.safeReference)
      return CommandFailure(
        error: selection, next: safe ? selection.next : ["silta ws ls"],
        nextBy: safe ? selection.nextBy : .agent, message: message)
    }
    let hub =
      workspace.map { DocService(workspace: $0, store: environment.db).listCommand }
      ?? "silta ws ls"
    guard let workspace, SecretGuard.matches(in: workspace).isEmpty,
      DocService.safeReference("doc:" + request.slug)
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
      let safe = preparation.next.allSatisfy(DocService.safeReference)
      next = safe ? preparation.next + [scopedRetry] : [hub]
      owner = safe ? preparation.nextBy : .agent
    } else {
      next =
        error.code == .notFound || error.code == .conflict || request.base != nil
        ? [read.showCommand("doc:" + request.slug), scopedRetry] : [scopedRetry]
      owner = .agent
    }
    return CommandFailure(error: error, next: next, nextBy: owner, message: message)
  }
}
