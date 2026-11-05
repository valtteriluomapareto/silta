package import Testing

/// Runs synchronous test bodies without occupying cooperative executor workers.
package struct BlockingTestScope: TestTrait, SuiteTrait, TestScoping {
  package init() {}
  package var isRecursive: Bool { true }

  package func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    try await function()
  }
}

extension Trait where Self == BlockingTestScope {
  /// Keeps blocking test bodies outside the cooperative pool.
  package static var blockingTestWork: Self { Self() }
}
