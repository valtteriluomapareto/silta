import Darwin
import Foundation

/// An advisory lock with at most five seconds of retry spacing, shared by processes.
final class BoundedFileLock {
  private let descriptor: Int32

  init(_ path: URL, clock: any Clock) throws {
    descriptor = open(path.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw StorageError.fileFailure(errno, at: path.path) }
    do {
      for attempt in 0...50 {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
        guard errno == EWOULDBLOCK || errno == EINTR else {
          throw StorageError.fileFailure(errno, at: path.path)
        }
        guard attempt < 50 else { throw StorageError.busy }
        clock.wait(milliseconds: 100)
      }
    } catch {
      close(descriptor)
      throw error
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
