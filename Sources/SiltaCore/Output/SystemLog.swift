import Darwin
package import Foundation
import Synchronization

/// File sink selected by the CLI: daily JSONL and optional verbose mirroring.
/// Retention and command lifecycle aggregation belong to the command boundary.
package final class SystemLog: Log {
  private let directory: URL
  private let verbose: FileHandle?
  private let lock = Mutex(())

  /// Does no I/O until `record`. Pass stderr explicitly for verbose CLI diagnostics.
  package init(directory: URL, verbose: FileHandle? = nil) {
    self.directory = directory
    self.verbose = verbose
  }

  /// Appends diagnostics best effort, without changing a completed command's result.
  package func record(_ entry: LogEntry) {
    try? write(entry)  // best-effort diagnostics must never fail a command
  }

  private func write(_ entry: LogEntry) throws {
    try lock.withLock { _ in
      let formatter = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(formatter))
      }
      let data = try encoder.encode(entry) + Data([10])
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let day = entry.timestamp.formatted(formatter).prefix(10)
      let url = directory.appending(path: "\(day).jsonl")
      let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try verbose?.write(contentsOf: data)
    }
  }
}
