package import Foundation

/// ULIDs with 80 bits of system entropy; the caller supplies time through Clock.
package struct SystemIDGenerator: IDGenerator {
  package init() {}

  package func next(at timestamp: Date) throws -> String {
    var random = SystemRandomNumberGenerator()  // guard:allow-nondeterminism entropy
    let entropy = (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &random) }
    return try ULID.encode(timestamp, entropy: entropy)
  }
}
