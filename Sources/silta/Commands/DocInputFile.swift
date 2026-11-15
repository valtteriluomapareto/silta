import Foundation
import SiltaCore

enum DocInputFile {
  static func read(_ file: String, command: String) throws -> String {
    do {
      let handle =
        try file == "-" ? FileHandle.standardInput : FileHandle(forReadingFrom: URL(filePath: file))
      defer { if file != "-" { try? handle.close() } }  // best-effort close cannot invalidate input
      return try DocInput.read { try handle.read(upToCount: $0) }
    } catch let error as any CodedError { throw error } catch {
      throw UsageError.invalid(message: "Cannot read doc input.", command: command)
    }
  }
}
