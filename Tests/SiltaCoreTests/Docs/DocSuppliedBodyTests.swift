import Foundation
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocSuppliedBodyTests {
  static let refusal = "Doc input must not contain NUL bytes."

  @Test(arguments: 0..<4)
  func nulRefusesShortReadsAndDirectStrings(example: Int) {
    let body = [
      "\u{0}tail", "Acme\u{0}tail", "é\u{0}", String(repeating: "a", count: 65_535) + "\u{0}",
    ][example]
    var bytes = Data(body.utf8)
    let read = Self.failure {
      _ = try DocInput.read { maximum in
        let chunk = bytes.prefix(min(maximum, 7))
        bytes.removeFirst(chunk.count)
        return Data(chunk)
      }
    }
    let direct = Self.failure { try DocInput.check(body) }
    #expect(read?.code == .invalid && read?.message == Self.refusal)
    #expect(direct?.code == .invalid && direct?.message == Self.refusal)
  }

  private static func failure(_ operation: () throws -> Void) -> (any CodedError)? {
    do { try operation() } catch let error as any CodedError { return error } catch {
      Issue.record("Unexpected input failure: \(error)")
    }
    return nil
  }
}
