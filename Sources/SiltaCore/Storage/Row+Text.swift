import Foundation
import GRDB

extension Row {
  /// Decodes stored text bytes without truncating or repairing them.
  func strictText(_ column: String) throws -> String? {
    try withUnsafeData(named: column) { bytes in
      guard let bytes else { return nil }
      guard let value = String(data: bytes, encoding: .utf8) else { throw StorageError.corrupt }
      return value
    }
  }
}
