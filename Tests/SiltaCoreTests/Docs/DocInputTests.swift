import Foundation
import Testing

@testable import SiltaCore

@Suite struct DocInputTests {
  @Test(arguments: [0, 1, 2])
  func boundedShortReadsPreserveLiteralUtf8(example: Int) throws {
    let text = ["", String(repeating: "a", count: 65_536), String(repeating: "é", count: 32_768)][
      example]
    var bytes = Data(text.utf8)
    let result = try BoundedInput.read(maximum: DocInput.maximumBytes) { maximum in
      let chunk = bytes.prefix(min(maximum, 7))
      bytes.removeFirst(chunk.count)
      return Data(chunk)
    }
    #expect(result == Data(text.utf8))
    try DocInput.check(text)
    #expect(bytes.isEmpty)
  }

  @Test func overflowReadsExactlyOneBytePastTheLimit() throws {
    var consumed = 0
    #expect(throws: BodyInputError.self) {
      _ = try BoundedInput.read(maximum: DocInput.maximumBytes) { maximum in
        consumed += maximum
        return Data(repeating: 97, count: maximum)
      }
    }
    #expect(consumed == 65_537)
    #expect(throws: StorageError.internalMisuse) {
      _ = try BoundedInput.read(maximum: DocInput.maximumBytes) { _ in
        throw StorageError.internalMisuse
      }
    }
  }

  static let refusal = "Doc input must not contain NUL bytes."

}
