import GRDB

/// Retries only raw SQLite lock contention, after the transaction has rolled back.
/// Caller-coded refusals are never repeated. Jitter supplies nonnegative milliseconds.
func withStorageRetry<T>(clock: any Clock, jitter: () -> UInt64, body: () throws -> T) throws -> T {
  var retries = 0
  while true {
    do {
      return try body()
    } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
      guard retries < 3 else { throw StorageError.busy }
      retries += 1
      clock.wait(milliseconds: jitter())
    }
  }
}
