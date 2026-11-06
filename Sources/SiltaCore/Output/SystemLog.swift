import Darwin
package import Foundation

/// File sink selected by the CLI: daily JSONL and optional verbose mirroring.
/// Keeps `retainedDays` UTC days using the command timestamp.
package final class SystemLog: Log {
  /// How many UTC days of logs are kept, today included. Long enough for a dogfood
  /// report to cover several waves (spec §19).
  package static let retainedDays = 90

  private let directory: URL
  private let verbose: FileHandle?

  /// Does no I/O until `record`. Pass stderr explicitly for verbose CLI diagnostics.
  package init(directory: URL, verbose: FileHandle? = nil) {
    self.directory = directory
    self.verbose = verbose
  }

  /// Appends diagnostics best effort, without changing a completed command's result.
  package func record(_ entry: LogEntry) {
    try? write(entry)  // best-effort diagnostics must never fail a command
  }

  /// Encodes one body-free daily record outside a timeout handler.
  package static func prepared(_ entry: LogEntry) throws -> (name: String, data: Data) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(utcTimestamp(date))
    }
    return (utcDay(entry.timestamp) + ".jsonl", try encoder.encode(entry) + Data([10]))
  }

  private func write(_ entry: LogEntry) throws {
    let record = try Self.prepared(entry)
    try Self.append(directory: directory, name: record.name, data: record.data)
    try verbose?.write(contentsOf: record.data)
    // A health inspection appends its result without removing retained evidence.
    if entry.command != "silta doctor" { try prune(at: entry.timestamp) }
  }

  private func prune(at timestamp: Date) throws {
    let oldest = utcDay(timestamp.addingTimeInterval(-Double(Self.retainedDays - 1) * 86400))
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    for file in files where file.lastPathComponent < oldest + ".jsonl" {
      guard file.lastPathComponent.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl/) != nil else {
        continue
      }
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isRegularFile == true && values.isSymbolicLink != true {
        try FileManager.default.removeItem(at: file)
      }
    }
  }
}
