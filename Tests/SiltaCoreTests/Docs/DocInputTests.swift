import Foundation
import Testing

@testable import SiltaCore

@Suite struct DocInputTests {
  @Test(arguments: [0, 1, 2])
  func boundedShortReadsPreserveLiteralUtf8(example: Int) throws {
    let text = ["", String(repeating: "a", count: 65_536), String(repeating: "é", count: 32_768)][
      example]
    var bytes = Data(text.utf8)
    let result = try DocInput.read { maximum in
      let chunk = bytes.prefix(min(maximum, 7))
      bytes.removeFirst(chunk.count)
      return Data(chunk)
    }
    #expect(result.utf8.elementsEqual(text.utf8))
    #expect(bytes.isEmpty)
  }

  @Test func readsOnlyLimitPlusOneAndRefusesInvalidUtf8OrReadFailure() throws {
    var consumed = 0
    #expect(throws: DocError.self) {
      _ = try DocInput.read { maximum in
        consumed += maximum
        return Data(repeating: 97, count: maximum)
      }
    }
    #expect(consumed == 65_537)
    var invalid = true
    #expect(throws: DocError.self) {
      _ = try DocInput.read { _ in
        defer { invalid = false }
        return invalid ? Data([0xc3]) : nil
      }
    }
    #expect(throws: StorageError.internalMisuse) {
      _ = try DocInput.read { _ in throw StorageError.internalMisuse }
    }
  }
}
