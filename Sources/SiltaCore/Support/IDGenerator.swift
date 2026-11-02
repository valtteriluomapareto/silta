package import Foundation

/// Creates canonical 26-character ULIDs using an explicitly supplied timestamp.
package protocol IDGenerator: Sendable {
  /// Rounds to the nearest millisecond. Throws for negative/nonfinite instants or
  /// rounded timestamps outside the unsigned 48-bit range.
  func next(at timestamp: Date) throws -> String
}

enum ULID {
  static func encode(_ timestamp: Date, entropy: [UInt8]) throws -> String {
    let seconds = timestamp.timeIntervalSince1970
    let milliseconds = (seconds * 1000).rounded()
    guard seconds.isFinite, seconds >= 0, milliseconds < 281_474_976_710_656 else {
      throw SeamError.invalidTimestamp
    }
    let time = UInt64(milliseconds)
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    var encoded = stride(from: 45, through: 0, by: -5).map { shift in
      alphabet[Int((time >> shift) & 31)]
    }
    var buffer: UInt32 = 0
    var bits = 0
    for byte in entropy {
      buffer = (buffer << 8) | UInt32(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        encoded.append(alphabet[Int((buffer >> bits) & 31)])
      }
      buffer &= (1 << bits) - 1
    }
    return String(encoded.map { Character(UnicodeScalar($0)) })
  }
}
