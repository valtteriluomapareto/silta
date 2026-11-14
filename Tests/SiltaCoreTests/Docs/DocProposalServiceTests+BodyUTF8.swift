import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocProposalServiceTests {
  @Test func suppliedProposalRetainsCompleteBodyBytes() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let service = try Self.service(home, store)
      for (index, body) in [
        "", "Acme\u{0}tail", "é\u{0}",
        "\u{0}" + String(repeating: "é", count: 32_767) + "x",
      ].enumerated() {
        let result = try service.propose(Self.request(), input: { body })
        #expect(result.ref == "doc:rules@\(index + 1)" && result.warnings.isEmpty)
        let bytes = try store.read {
          try Data.fetchOne(
            $0, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev WHERE rev=?",
            arguments: [index + 1])
        }
        #expect(bytes == Data(body.utf8))
        #expect(
          try store.read {
            try String.fetchOne(
              $0, sql: "SELECT typeof(body_md) FROM doc_rev WHERE rev=?",
              arguments: [index + 1])
          } == "text")
      }
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev WHERE state='proposed'")
        } == 4)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_verification") } == 0)
    }
  }
}
