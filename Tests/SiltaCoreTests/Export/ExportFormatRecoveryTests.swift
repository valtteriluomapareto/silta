import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportFormatRecoveryTests {
  static func files(format: String) throws -> [String: Data] {
    var files = try ExportVersionTests.frozen()
    let data = try #require(files["manifest.json"])
    let manifest = try #require(String(data: data, encoding: .utf8))
    files["manifest.json"] = Data(
      manifest.replacingOccurrences(
        of: #""format": "1""#, with: "\"format\": " + ExportFormat.quote(format)
      ).utf8)
    return files
  }

  @Test(arguments: ["3", "10", "999999999999999999999999999999"])
  func futureFormatsAskForAnUpdate(format: String) throws {
    do {
      _ = try ExportTree.parse(Self.files(format: format))
      Issue.record("Restored an unsupported future format")
    } catch let error as ExportError {
      withKnownIssue("Future formats ask for another incompatible export") {
        #expect(error.code == .env)
        #expect(error.nextBy == .human)
        #expect(error.next == ["update silta"])
        if format == "3" {
          let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
          let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
          #expect(text.exitCode == 9 && json.exitCode == 9)
          Golden.forTests().check(text.stderr + json.stdout, "export-newer-format-error.txt")
        }
      }
    }
  }

  @Test(arguments: ["", "0", "-1", "01", "03", "+3", "3.0", "3e0", " 3", "٣", "future"])
  func malformedAndOlderUnsupportedFormatsKeepTreeRecovery(format: String) throws {
    do {
      _ = try ExportTree.parse(Self.files(format: format))
      Issue.record("Restored an unsupported format")
    } catch let error as ExportError {
      #expect(error.code == .invalid)
      #expect(error.nextBy == .human)
      #expect(
        error.next == [
          "silta --ws <the tree's workspace> export  # again, on the machine the tree came from"
        ])
    }
  }

  @Test(arguments: [false, true], [false, true])
  func futureRestoreChangesNoStorage(dryRun: Bool, initialized: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = initialized ? try ExportFixture.make(home) : ExportFixture.store(home)
      if initialized { try RestoreSupport.settle(store) }
      let before = initialized ? try RestoreSupport.dump(store) : [:]
      let backups = try RestoreSupport.backups(home)
      let tree = try RestoreSupport.write(
        Self.files(format: "3"), to: scratch.appending(path: "tree/acme"))
      do {
        _ = try RestoreSupport.restore(tree, into: store, home: home, dryRun: dryRun)
        Issue.record("Restored an unsupported future format")
      } catch let error as ExportError {
        withKnownIssue("Future formats ask for another incompatible export") {
          #expect(error.code == .env)
          #expect(error.next == ["update silta"])
        }
      }
      #expect(try RestoreSupport.backups(home) == backups)
      if initialized {
        #expect(try RestoreSupport.dump(store) == before)
      } else {
        #expect(!FileManager.default.fileExists(atPath: home.path))
      }
    }
  }
}
