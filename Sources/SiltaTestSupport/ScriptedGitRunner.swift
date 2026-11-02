package import SiltaCore
import Synchronization

/// Replays expected requests in order. Mismatches throw without consuming a step.
package final class ScriptedGitRunner: GitRunner {
  private struct State {
    var steps: [(GitRequest, Result<GitResult, any Error>)]
    var requests: [GitRequest] = []
  }
  private let state: Mutex<State>

  package init(steps: [(GitRequest, GitResult)]) {
    state = Mutex(State(steps: steps.map { ($0.0, .success($0.1)) }))
  }

  /// Scripts spawn/capture failures as well as completed invocations.
  package init(script: [(GitRequest, Result<GitResult, any Error>)]) {
    state = Mutex(State(steps: script))
  }
  package var requests: [GitRequest] { state.withLock { $0.requests } }
  package var isExhausted: Bool { state.withLock { $0.steps.isEmpty } }

  package func run(_ request: GitRequest) async throws -> GitResult {
    try state.withLock { state in
      state.requests.append(request)
      guard let step = state.steps.first, step.0 == request else {
        throw ScriptError.unexpectedRequest
      }
      state.steps.removeFirst()
      return try step.1.get()
    }
  }
}

private enum ScriptError: Error { case unexpectedRequest }
