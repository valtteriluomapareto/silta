#if DEBUG
  import Foundation
  @testable import SiltaApp

  @MainActor final class ControlledLoads {
    struct Request {
      let id: Int
      let previous: AppLoadedData?
      let workspace: String?
      let force: Bool
      let continuation: CheckedContinuation<AppLoadedData?, any Error>
    }
    private var requests: [Request] = []
    private var nextID = 0
    private var terminal: AppLoadedData??
    private var waiting: CheckedContinuation<Request, Never>?
    private var active: [Request] = []

    func load(_ previous: AppLoadedData?, _ workspace: String?, _ force: Bool) async throws
      -> AppLoadedData?
    {
      if let terminal { return terminal }
      return try await withCheckedThrowingContinuation { continuation in
        nextID += 1
        let request = Request(
          id: nextID, previous: previous, workspace: workspace, force: force,
          continuation: continuation)
        active.append(request)
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

    func finish(_ request: Request, _ result: Result<AppLoadedData?, any Error>) {
      active.removeAll { $0.id == request.id }
      request.continuation.resume(with: result)
    }

    func finishAll(_ value: AppLoadedData?) {
      terminal = .some(value)
      let pending = active
      active = []
      requests = []
      for request in pending { request.continuation.resume(returning: value) }
    }
  }
#endif
