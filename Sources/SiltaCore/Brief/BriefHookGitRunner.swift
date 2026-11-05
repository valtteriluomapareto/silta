/// Bounds hook Git reads to the hook's remaining process budget and reports deadlines.
package struct BriefHookGitRunner: GitRunner {
  let runner: any GitRunner
  let deadline: BriefHookDeadline
  let onTimeout: @Sendable () -> Void

  package init(
    runner: any GitRunner, deadline: BriefHookDeadline,
    onTimeout: @escaping @Sendable () -> Void
  ) {
    self.runner = runner
    self.deadline = deadline
    self.onTimeout = onTimeout
  }

  /// Runs without lazy fetching. Expired budgets avoid spawning and still notify the caller.
  package func run(_ request: GitRequest) async throws -> GitResult {
    let seconds = deadline.childSeconds
    guard seconds > 0 else {
      onTimeout()
      return GitResult(termination: .timedOut)
    }
    let result = try await runner.run(
      .init(
        arguments: request.arguments,
        directory: request.directory, timeout: min(request.timeout, seconds), lazyFetch: false))
    if result.termination == .timedOut { onTimeout() }
    return result
  }
}
