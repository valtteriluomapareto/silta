/// Runs long synchronous test work while suspending the calling task.
package func withBlockingTestWork<T: Sendable>(
  _ body: @escaping @Sendable () throws -> T
) async throws -> T {
  try body()
}
