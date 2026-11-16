import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocObservedUIDRestoreTests {
  @Test(arguments: ["absent", "null", "removed"])
  func historicalEvidencePreservesUnknownAndRemovedAppUIDs(mode: String) throws {
    try withScratchDirectory { home in
      let (source, expected) = try Self.source(home, mode: mode)
      let files = try ExportTreeTests.render(source)
      let directory = try RestoreSupport.write(files, to: home.appending(path: "export"))
      let destinationHome = home.appending(path: "destination")
      let destination = ExportFixture.store(destinationHome)
      try destination.initialize()
      _ = try RestoreSupport.restore(directory, into: destination, home: destinationHome)
      #expect(
        try destination.read {
          try String.fetchOne($0, sql: "SELECT app_shas FROM doc_verification")
        } == expected)
      #expect(
        try destination.read {
          try String.fetchOne($0, sql: "SELECT uid FROM app WHERE slug='api'")
        } == "replacement-app")
    }
  }

  @Test(arguments: ["empty", "unicode", "nul", "number", "array"])
  func suppliedEvidenceUIDMustBeAnAdmittedStringBeforeRestore(mode: String) throws {
    withKnownIssue("SI-126/38: supplied evidence UID must be admitted before restore") {
      try withScratchDirectory { home in
        let (source, _) = try Self.source(home, mode: mode)
        let directory = try RestoreSupport.exportTree(source, to: home.appending(path: "export"))
        let destinationHome = home.appending(path: "destination")
        let destination = ExportFixture.store(destinationHome)
        try destination.initialize()
        let before = try RestoreSupport.dump(destination)
        var failure: (any CodedError)?
        do {
          _ = try RestoreSupport.restore(directory, into: destination, home: destinationHome)
        } catch let error as any CodedError { failure = error }
        #expect(failure?.code == .invalid)
        #expect(try RestoreSupport.dump(destination) == before)
        #expect(!(failure?.message.contains("K\u{0}tail") ?? false))
      }
    }
  }

  private static func source(_ home: URL, mode: String) throws -> (DatabaseStore, String) {
    let store = try AcmeDocAttachments.make(in: home)
    var draft = DocDraft(slug: "rules", body: "Historical Acme knowledge")
    draft.title = "Rules"
    draft.about = ["app:api"]
    _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 71))
    _ = try DocWritePolicyTests.service(home, store).archive("rules")
    let original = try #require(
      try store.read {
        try String.fetchOne($0, sql: "SELECT uid FROM app WHERE slug='api'")
      })
    var fields: [String: Any] = [
      "app": "api", "ref": "main", "sha": String(repeating: "f", count: 40),
    ]
    switch mode {
    case "absent": break
    case "null": fields["uid"] = NSNull()
    case "removed": fields["uid"] = original
    case "empty": fields["uid"] = ""
    case "unicode": fields["uid"] = "K"
    case "nul": fields["uid"] = "K\u{0}tail"
    case "number": fields["uid"] = 42
    default: fields["uid"] = ["K"]
    }
    let bytes = try JSONSerialization.data(withJSONObject: [fields], options: [.sortedKeys])
    let evidence = try #require(String(data: bytes, encoding: .utf8))
    try store.write {
      try $0.database.execute(sql: "UPDATE app SET uid='replacement-app' WHERE slug='api'")
      try $0.database.execute(sql: "UPDATE doc_verification SET app_shas=?", arguments: [evidence])
    }
    return (store, evidence)
  }
}
