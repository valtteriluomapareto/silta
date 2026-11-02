package import Foundation
import SiltaCore

/// Replays a seeded ULID sequence without system randomness.
package struct FakeIDGenerator: IDGenerator {
  private let generator: SeededIDGenerator

  package init(seed: UInt64) { generator = SeededIDGenerator(seed: seed) }
  package func next(at timestamp: Date) throws -> String { try generator.next(at: timestamp) }
}
