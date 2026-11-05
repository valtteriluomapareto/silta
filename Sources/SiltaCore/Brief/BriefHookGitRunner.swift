/// Bounds hook Git reads to the caller's remaining process budget and reports deadlines.
package struct BriefHookGitRunner: GitRunner {
  let runner: any GitRunner
  let remaining: @Sendable () -> Double
  let onTimeout: @Sendable () -> Void

  /// The caller reserves child cleanup time before returning its remaining seconds.
  package init(
    runner: any GitRunner, remaining: @escaping @Sendable () -> Double,
    onTimeout: @escaping @Sendable () -> Void
  ) {
    self.runner = runner
    self.remaining = remaining
    self.onTimeout = onTimeout
  }

  /// Runs without lazy fetching. Expired budgets avoid spawning and still notify the caller.
  package func run(_ request: GitRequest) async throws -> GitResult {
    let seconds = remaining()
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
