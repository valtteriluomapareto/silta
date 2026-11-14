extension DocProposalService {
  func recovery(_ error: any CodedError, request: DocProposalRequest) -> any CodedError {
    if error is StorageError { return error }
    let hub =
      workspace.map { DocService(workspace: $0, store: environment.db).listCommand }
      ?? "silta ws ls"
    let message = SecretGuard.redacted(error.message)
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
    let next =
      error.code == .notFound || error.code == .conflict || request.base != nil
      ? [read.showCommand("doc:" + request.slug), workspaceCommand(retry, workspace: workspace)]
      : [workspaceCommand(retry, workspace: workspace)]
    return CommandFailure(error: error, next: next, nextBy: .agent, message: message)
  }
}
