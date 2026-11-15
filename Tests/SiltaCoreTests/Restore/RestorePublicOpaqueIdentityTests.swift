import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestorePublicOpaqueIdentityTests {
  @Test(
    arguments: [
      "ghp_" + String(repeating: "x", count: 36), String(repeating: "a", count: 52),
      "opaque-ordinary",
    ], [false, true])
  func publicForeignUIDConflictMasksDiagnosticsAndWritesNothing(_ uid: String, dryRun: Bool) throws
  {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      try target.write {
        try $0.database.execute(sql: "UPDATE doc SET uid=? WHERE id=92", arguments: [uid])
      }
      var tree = try RestoreDocumentGraphFixture.graph().tree
      RestoreOpaqueIdentityFixture.rename(&tree, from: ExportDocumentTests.uid("001"), to: uid)
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      let files = try tree.files()
      #expect(try #require(files["docs/push-rules.md"]).range(of: Data(uid.utf8)) != nil)
      let directory = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      let before = try RestoreSupport.dump(target)
      let backups = try RestoreSupport.backups(home)
      do {
        _ = try RestoreSupport.restore(directory, into: target, home: home, dryRun: dryRun)
        Issue.record("Restored another workspace's literal document UID")
      } catch let error as ExportError {
        #expect(error.code == .conflict && error.next == ["silta ws ls"] && error.nextBy == .human)
        #expect(error.message.contains("belongs to another workspace"))
        for json in [false, true] {
          let output = OutputRouter.render(.failure(error), mode: OutputMode(json: json))
          if uid == "opaque-ordinary" {
            #expect((output.stdout + output.stderr).contains(uid))
          } else {
            #expect(!(output.stdout + output.stderr).contains(uid))
          }
        }
      }
      #expect(try RestoreSupport.dump(target) == before)
      #expect(try RestoreSupport.backups(home) == backups)
      ExportTreeTests.expectSame(try RestoreService.readTree(directory), files)
      let stored = try target.read {
        try String.fetchOne($0, sql: "SELECT uid FROM doc WHERE id=92")
      }
      #expect(stored.map { Data($0.utf8) } == Data(uid.utf8))
    }
  }

}
