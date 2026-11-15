import Foundation
import Testing

@testable import SiltaCore

extension ExportVersionTests {
  @Test(arguments: ["both", "doc_rev", "next"])
  func legacyReservationsRequireBothStringFields(missing: String) throws {
    var values = ["doc_rev": "discarded-owner", "next": "unused"]
    if missing == "both" {
      values.removeAll()
    } else {
      values[missing] = nil
    }
    let files = try Self.legacyCounterFiles(values)
    do {
      var failure: ExportError?
      do { _ = try ExportTree.parse(files) } catch let error as ExportError { failure = error }
      #expect(failure?.code == .invalid)
      #expect(failure?.message.contains("doc_rev and next") == true)
    }
  }

  @Test(arguments: [false, true])
  func completeLegacyCounterValuesStayUninterpreted(empty: Bool) throws {
    let values =
      empty
      ? ["doc_rev": "", "next": ""]
      : ["doc_rev": "discarded-owner", "next": "not-a-number"]
    let files = try Self.legacyCounterFiles(values)
    let parsed = try ExportTree.parse(files)
    #expect(parsed.format == "2")
    #expect(parsed.documents.legacyCommentSequences?.first?.value("doc_rev") == values["doc_rev"])
    #expect(parsed.documents.legacyCommentSequences?.first?.value("next") == values["next"])
    ExportTreeTests.expectSame(try parsed.files(), files)
  }

  static func legacyCounterFiles(_ values: [String: String]) throws -> [String: Data] {
    var snapshot = try ExportTree.parse(Self.frozenTwo())
    snapshot.documents.legacyCommentSequences = [
      ExportRow(keys: ["doc_rev", "next"], values: values)
    ]
    return try snapshot.files()
  }
}
