import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportDocumentCounterTests {
  @Test(arguments: ["0", "-1", "071", "9223372036854775808"])
  func refusesNoncanonicalOrUnrepresentableFloors(_ value: String) throws {
    var files = try ExportDocumentSnapshotTests.golden()
    let path = ExportFormat.docAllocationsFile
    files[path] = Data(
      text(files[path] ?? Data()).replacingOccurrences(
        of: #""next": "71""#, with: "\"next\": " + ExportFormat.quote(value)
      ).utf8)
    #expect(throws: ExportError.self) {
      try ExportDocumentSnapshot.parse(files, workspace: "acme")
    }
  }

  @Test(arguments: [
    "missing allocation stream", "missing doc floor", "revision collision",
    "unsafe slug", "duplicate row", "unknown field", "unordered rows", "orphan jsonl",
  ])
  func refusesIncompleteOrIgnoredCounterTruth(_ damage: String) throws {
    var files = try ExportDocumentSnapshotTests.golden()
    let allocations = ExportFormat.docAllocationsFile
    if !Self.remove(&files, damage) {
      switch damage {
      case "revision collision":
        Self.replace(&files, allocations, #""next": "20""#, #""next": "7""#)
      case "unsafe slug": Self.replace(&files, allocations, "gone-rules", "../gone-rules")
      case "duplicate row":
        files[allocations]?.append(
          Data(#"{"slug": "gone-rules", "next": "71"}"#.appending("\n").utf8))
      case "unknown field":
        Self.replace(&files, allocations, #""next": "71""#, #""next": "71", "future": "ignored""#)
      case "unordered rows":
        files[allocations] = Data(
          (text(files[allocations] ?? Data()).split(separator: "\n")
            .reversed().joined(separator: "\n") + "\n").utf8)
      default: files["docs/push-rules.md"] = nil
      }
    }
    #expect(throws: ExportError.self) {
      try ExportDocumentSnapshot.parse(files, workspace: "acme")
    }
  }

  static func remove(_ files: inout [String: Data], _ damage: String) -> Bool {
    let allocations = ExportFormat.docAllocationsFile
    switch damage {
    case "missing allocation stream": files[allocations] = nil
    case "missing doc floor":
      files[allocations] = Data(
        (text(files[allocations] ?? Data()).split(separator: "\n")
          .filter { !$0.contains("push-rules") }.joined(separator: "\n") + "\n").utf8)
    default: return false
    }
    return true
  }

  static func replace(_ files: inout [String: Data], _ path: String, _ old: String, _ new: String) {
    files[path] = Data(text(files[path] ?? Data()).replacingOccurrences(of: old, with: new).utf8)
  }

  @Test func emptyWorkspaceStillHasBothCanonicalStreams() throws {
    let files: [String: Data] = [
      ExportFormat.docAllocationsFile: Data(), ExportFormat.docCommentSequencesFile: Data(),
    ]
    let snapshot = try ExportDocumentSnapshot.parse(files, workspace: "acme")
    #expect(snapshot.documents.isEmpty)
    #expect(snapshot.revisionAllocations.isEmpty)
    #expect(snapshot.legacyCommentSequences == [])
    ExportTreeTests.expectSame(try snapshot.files(), files)
  }
}
