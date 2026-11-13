package import Foundation

/// Bounded, strict UTF-8 supplied document input. Retained bodies do not pass this loader.
package enum DocInput {
  /// The fixed supplied-input byte limit, before and after redaction.
  package static let maximumBytes = 64 * 1024

  /// Reads at most limit+1 bytes across short reads and refuses oversized or invalid UTF-8.
  package static func read(nextBytes: (Int) throws -> Data?) throws -> String {
    var bytes = Data()
    while let chunk = try nextBytes(maximumBytes + 1 - bytes.count), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= maximumBytes else {
        throw DocError.invalid("Doc input exceeds 65536 bytes.")
      }
    }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw DocError.invalid("Doc input must be UTF-8.")
    }
    return text
  }

  static func check(_ text: String) throws {
    guard text.utf8.count <= maximumBytes else {
      throw DocError.invalid("Doc input exceeds 65536 bytes.")
    }
  }
}
