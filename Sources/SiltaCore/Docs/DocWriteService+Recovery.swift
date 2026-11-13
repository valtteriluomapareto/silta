extension DocWriteService {
  func recovery(_ error: any CodedError, request: DocEditRequest, workspace: String)
    -> any CodedError
  {
    if error is StorageError { return error }
    let message = SecretGuard.redacted(error.message)
    guard safeScopeAndIdentity(request, workspace: workspace) else {
      return CommandFailure(
        error: error, next: [readCommand(workspace: workspace)], nextBy: .agent, message: message)
    }
    if error is RepoError || error is CodeError {
      let safe = error.next.allSatisfy(DocService.safeReference)
      return CommandFailure(
        error: error,
        next: safe
          ? error.next
          : [DocService(workspace: workspace, store: environment.db).configurationCommand],
        nextBy: safe ? nil : .agent, message: message)
    }
    if case .missing(let fields) = error as? DocError {
      return CommandFailure(
        error: error, next: [retry(request, fields: fields, workspace: workspace)], message: message
      )
    }
    if error is SecretError {
      return CommandFailure(
        error: error, next: [retry(request, allowSecret: true, workspace: workspace)],
        nextBy: .human, message: message)
    }
    if error.code == .notFound || error.code == .conflict {
      let read = DocService(workspace: workspace, store: environment.db)
      return CommandFailure(
        error: error, next: [read.configurationCommand], nextBy: .agent, message: message)
    }
    return CommandFailure(
      error: error, next: [retry(request, workspace: workspace)], message: message)
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
