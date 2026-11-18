#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport

  /// Holds each write until the test finishes it, so in-flight states are observable.
  @MainActor final class ControlledWrites {
    struct Request {
      let write: AppWrite
      let workspace: String
      let continuation: CheckedContinuation<Void, any Error>
    }
    private var requests: [Request] = []
    private var waiting: CheckedContinuation<Request, Never>?

    func write(_ write: AppWrite, _ workspace: String) async throws {
      try await withCheckedThrowingContinuation { continuation in
        let request = Request(write: write, workspace: workspace, continuation: continuation)
        if let waiting {
          self.waiting = nil
          waiting.resume(returning: request)
        } else {
          requests.append(request)
        }
      }
    }

    func next() async -> Request {
      if !requests.isEmpty { return requests.removeFirst() }
      return await withCheckedContinuation { waiting = $0 }
    }
  }
#endif
