extension DocWriteService {
  func recovery(_ error: any CodedError, request: DocEditRequest, workspace: String)
    -> CommandFailure
  {
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return CommandFailure(error: error, next: [readCommand(workspace: workspace)], nextBy: .agent)
    }
    if case .missing(let fields) = error as? DocError {
      return CommandFailure(
        error: error, next: [retry(request, fields: fields, workspace: workspace)])
    }
    if error is SecretError {
      return CommandFailure(
        error: error, next: [retry(request, allowSecret: true, workspace: workspace)],
        nextBy: .human)
    }
    if error.code == .notFound || error.code == .conflict {
      let read = DocService(workspace: workspace, store: environment.db)
      return CommandFailure(error: error, next: [read.configurationCommand], nextBy: .agent)
    }
    return CommandFailure(error: error, next: [retry(request, workspace: workspace)])
  }

  func retry(
    _ request: DocEditRequest, fields: [String] = [], allowSecret: Bool = false,
    workspace: String?
  ) -> String {
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return readCommand(workspace: workspace)
    }
    var retry = request
    if fields.contains("-F") { retry.keepBody = false }
    if fields.contains("--title") { retry.title = "" }
    if fields.contains("--about") { retry.about = [] }
    retry.allowSecret = retry.allowSecret || allowSecret
    return command(retry, workspace: workspace)
      + (environment.actor.isHuman ? "" : " --approved \"<the human's words>\"")
  }
}
