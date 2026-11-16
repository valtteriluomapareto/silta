import Foundation
import GRDB

extension Row {
  /// Decodes a BLOB text projection without truncating or repairing its bytes.
  func strictText(_ column: String) throws -> String? {
    guard let bytes: Data = self[column] else { return nil }
    guard let value = String(data: bytes, encoding: .utf8) else { throw StorageError.corrupt }
    return value
  }
}
