import Foundation

/// Validates incoming restore identity bytes.
enum StoredUID {
  static func valid(_ bytes: Data) -> Bool {
    !bytes.isEmpty && bytes.allSatisfy { $0 > 0 && $0 < 128 }
  }

}
