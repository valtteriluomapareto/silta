import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct AskAboutRestoreTests {
  @Test(arguments: ["{}", #"{"ask_about":"standard"}"#, #"{"ask_about":"short"}"#])
  func settingsRoundTripAndDryRunNamesChange(_ json: String) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "source")
      let source = try ExportFixture.make(home)
      try source.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET settings=? WHERE slug='acme'", arguments: [json])
      }
      let tree = try RestoreSupport.exportTree(source, to: scratch.appending(path: "tree"))
      let targetHome = scratch.appending(path: "target")
      let target = ExportFixture.store(targetHome)
      try target.initialize()
      let preview = try RestoreSupport.restore(tree, into: target, home: targetHome, dryRun: true)
      if json.contains("short") {
        #expect(preview.settings.contains { $0.key == "ask_about" && $0.after == #""short""# })
      }
      _ = try RestoreSupport.restore(tree, into: target, home: targetHome)
      #expect(
        try target.read { try String.fetchOne($0, sql: "SELECT settings FROM workspace") } == json)
      ExportTreeTests.expectSame(
        try ExportTreeTests.render(target), try ExportTreeTests.render(source))
    }
  }

  @Test(arguments: [#""future""#, "false", "null", "42", "[]", "{}"], [false, true])
  func invalidAskAboutRestoresChangeNothing(_ value: String, dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "source")
      let source = try ExportFixture.make(home)
      try source.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET settings=? WHERE slug='acme'",
          arguments: ["{\"ask_about\":\(value)}"])
      }
      let tree = try RestoreSupport.exportTree(source, to: scratch.appending(path: "tree"))
      let targetHome = scratch.appending(path: "target")
      let target = try ExportFixture.make(targetHome)
      try RestoreSupport.settle(target)
      let before = try RestoreSupport.dump(target)
      let backups = try RestoreSupport.backups(targetHome)
      #expect(throws: ExportError.self) {
        _ = try RestoreSupport.restore(tree, into: target, home: targetHome, dryRun: dryRun)
      }
      #expect(try RestoreSupport.dump(target) == before)
      #expect(try RestoreSupport.backups(targetHome) == backups)
    }
  }
}
