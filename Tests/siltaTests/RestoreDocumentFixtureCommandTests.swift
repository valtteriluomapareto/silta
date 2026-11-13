import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentFixtureCommandTests {
  @Test func documentPublicationPreservesDatabaseAndExistingTreeData() throws {
    try withScratchDirectory { scratch in
      try RestoreDocumentCommandFixture.seed(scratch)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      let root = scratch.appending(path: "work/out")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let marker = root.appending(path: "keep.txt")
      let bytes = Data("Acme retained data.\n".utf8)
      try bytes.write(to: marker)
      let before = try RestoreDocumentCommandFixture.dump(queue)
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "export", "--to", "out"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
        #expect(try Data(contentsOf: marker) == bytes)
        let document = root.appending(path: "acme/docs/rules.md")
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(try Data(contentsOf: document).range(of: Data("Original rule.".utf8)) != nil)
      }
    }
  }
}
