import Foundation
import SiltaCore
import Testing

struct ShapeTests {
  private func encoded(_ shape: Shape) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try #require(String(bytes: try encoder.encode(shape), encoding: .utf8))
  }

  @Test func encodesTheSpecForm() throws {
    let shape = Shape.object([
      "a": .array(.string), "b": .bool, "i": .int, "o": .optional(.any),
    ])
    #expect(
      try encoded(shape)
        == #"{"object":{"a":{"array":"string"},"b":"bool","i":"int","o":{"optional":"any"}}}"#)
  }
}
