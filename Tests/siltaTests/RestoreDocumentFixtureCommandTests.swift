import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentFixtureCommandTests {
  @Test func documentExportRefusalPreservesDatabaseAndExistingTreeData() throws {
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
        #expect(result.termination == .exit(9), "\(result.stdout)\(result.stderr)")
        #expect((result.stdout + result.stderr).contains("can't export"))
        #expect((result.stdout + result.stderr).contains("update silta"))
        #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "acme").path))
      }
    }
  }
}
