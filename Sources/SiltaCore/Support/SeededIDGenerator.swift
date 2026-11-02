package import Foundation
import Synchronization

/// Reproducible ULIDs. Each id consumes two SplitMix64 words, low byte first;
/// the first ten bytes are kept and the remaining six are discarded.
/// This generator is for deterministic runs, not cryptographic identifiers.
package final class SeededIDGenerator: IDGenerator {
  private let state: Mutex<UInt64>

  /// Starts the reproducible entropy sequence at `seed`.
  package init(seed: UInt64) {
    state = Mutex(seed)
  }

  /// Creates the next ULID, using the supplied instant.
  package func next(at timestamp: Date) throws -> String {
    try state.withLock { state in
      var entropy: [UInt8] = []
      for _ in 0..<2 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var word = state
        word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
        word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
        word ^= word >> 31
        entropy += (0..<8).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
      }
      return try ULID.encode(timestamp, entropy: Array(entropy.prefix(10)))
    }
  }
}
