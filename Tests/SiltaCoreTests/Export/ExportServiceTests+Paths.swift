import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension ExportServiceTests {
  @Test(arguments: ["slug", "task_prefix", "service"])
  func malformedStoredIdentifierDoesNotPublish(field: String) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let nested = "acme/research"
      let slug = field == "slug" ? nested : "acme"
      try store.write {
        let sql =
          field == "service"
          ? "UPDATE service SET slug=? WHERE slug='mailer'"
          : "UPDATE workspace SET \(field)=? WHERE slug='acme'"
        try $0.database.execute(sql: sql, arguments: [nested])
      }
      let fm = FileManager.default
      let surroundings = try Set(fm.contentsOfDirectory(atPath: scratch.path))
      let fields = [
        "slug": "workspace slug", "task_prefix": "task prefix", "service": "service slug",
      ]
      let name = try #require(fields[field])
      #expect(
        throws: ExportError.invalidExport(
          reason: "the \(name) is not an identifier", workspace: slug)
      ) {
        try ExportService.export(workspace: slug, to: root, store: store, home: home)
      }
      #expect(try Set(fm.contentsOfDirectory(atPath: scratch.path)) == surroundings)
      #expect(!fm.fileExists(atPath: root.path))
    }
  }

  @Test func aLinkedManifestCannotAuthorizeReplacement() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      _ = try Self.export(store, home, to: root)
      let fm = FileManager.default
      let leaf = root.appending(path: "acme/manifest.json")
      let outside = scratch.appending(path: "outside-manifest.json")
      let original = try Data(contentsOf: leaf)
      try fm.moveItem(at: leaf, to: outside)
      try fm.createSymbolicLink(at: leaf, withDestinationURL: outside)
      #expect(throws: ExportError.self) {
        try Self.export(store, home, to: root)
      }
      #expect(try fm.destinationOfSymbolicLink(atPath: leaf.path) == outside.path)
      #expect(try Data(contentsOf: outside) == original)
    }
  }
}
