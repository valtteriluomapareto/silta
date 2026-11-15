import Foundation
import GRDB

/// Admits complete stored identity bytes before ordinary String comparisons.
enum StoredUID {
  static func valid(_ bytes: Data) -> Bool {
    !bytes.isEmpty && bytes.allSatisfy { $0 > 0 && $0 < 128 }
  }

  static var unsupported: CommandFailure {
    CommandFailure(
      error: StorageError.corrupt, next: ["silta backup"], nextBy: .human,
      message: "Stored IDs must be nonempty ASCII text without NUL. Nothing was changed. "
        + "Create a database backup and ask the human to inspect it before repairing IDs.")
  }

  static func read(_ column: String = "uid", from row: Row) throws -> String? {
    let value: DatabaseValue = row[column]
    switch value.storage {
    case .null: return nil
    case .string:
      return try row.withUnsafeData(named: column) { bytes in
        guard let bytes, valid(bytes), let uid = String(data: bytes, encoding: .utf8) else {
          throw unsupported
        }
        return uid
      }
    default: throw unsupported
    }
  }

  static func fetch(_ db: Database, sql: String, arguments: StatementArguments) throws -> String? {
    let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
    defer { withExtendedLifetime(cursor) {} }
    guard let row = try cursor.next() else { return nil }
    return try read(from: row)
  }
}
