import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing
import Yams

@Suite(.timeLimit(.minutes(1)))
struct ExportCommandTests {
  static let environment = [
    "SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z",
    "SILTA_ID_SEED": "7",
  ]

  /// An Acme workspace built through real commands, with values YAML 1.1 would retype.
  static func seed(_ scratch: URL) throws {
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix,settings)
          VALUES('01HZACME00000000000000WS01','acme','no','AC','{"review_gate":"none"}')
          """)
    }
    for arguments in [
      [
        "--ws", "acme", "task", "add", "--start", "0123: on #x", "-m", "Use the API.\n~~~\n",
        "--app", "none",
      ],
      ["--ws", "acme", "comment", "AC-1", "-m", "Which callback URL?", "--kind", "question"],
      ["--ws", "acme", "task", "plan", "AC-1", "-m", "- [ ] Inspect"],
    ] {
      let result = try SiltaBinary.run(arguments, in: scratch, environment: environment)
      #expect(result.termination == .exit(0), "\(arguments): \(result.stderr)")
    }
  }

  static func masked(_ text: String, _ scratch: URL) -> String {
    let path = scratch.path
    let short = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    return text.replacingOccurrences(of: path, with: "<scratch>")
      .replacingOccurrences(of: short, with: "<scratch>")
  }

  @Test func exportsToTheDefaultRootWithTextAndJSONReceipts() throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let text = try SiltaBinary.run(["--ws", "acme", "export"], in: scratch)
      #expect(text.termination == .exit(0), "\(text.stderr)")
      Golden.forTests().check(Self.masked(text.stdout, scratch), "export.txt")
      let json = try SiltaBinary.run(["--ws", "acme", "export", "--json"], in: scratch)
      #expect(json.termination == .exit(0))
      Golden.forTests().check(Self.masked(json.stdout, scratch), "export.json")
      let manifest = scratch.appending(path: "silta-home/exports/acme/manifest.json")
      #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
  }

  @Test func relativeRootResolvesAgainstTheWorkingDirectory() throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "export", "--to", "out", "--quiet"], in: scratch)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      #expect(result.stdout.isEmpty)
      #expect(
        FileManager.default.fileExists(
          atPath: scratch.appending(path: "work/out/acme/workspace.yaml").path))
    }
  }

  /// A YAML parser reads every scalar back as the stored string: nothing is retyped.
  @Test func yamlParsersReadTheStoredStrings() throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let result = try SiltaBinary.run(["--ws", "acme", "export", "--to", "out"], in: scratch)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      let tree = scratch.appending(path: "work/out/acme")
      let workspace = try #require(
        try Yams.load(
          yaml: try String(contentsOf: tree.appending(path: "workspace.yaml"), encoding: .utf8))
          as? [String: Any])
      let row = try #require(workspace["workspace"] as? [String: Any])
      #expect(row["name"] as? String == "no")
      #expect(row["settings"] as? String == #"{"review_gate":"none"}"#)
      #expect(row["next_task_seq"] as? String == "2")
      #expect(workspace["repos"] is [Any])
      let markdown = try String(contentsOf: tree.appending(path: "tasks/AC-1.md"), encoding: .utf8)
      let parts = markdown.components(separatedBy: "---\n")
      let frontmatter = try #require(try Yams.load(yaml: parts[1]) as? [String: Any])
      #expect(frontmatter["title"] as? String == "0123: on #x")
      #expect(frontmatter["seq"] as? String == "1")
      #expect(frontmatter["priority"] as? String == "2")
      #expect(frontmatter["worktree"] == nil)
      #expect(markdown.contains("## Description\n~~~~\nUse the API.\n~~~\n\n~~~~\n"))
      let events = try String(contentsOf: tree.appending(path: "tasks/AC-1.jsonl"), encoding: .utf8)
      for line in events.split(separator: "\n") {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        #expect(object is [String: String])
      }
      let text = try ExportServiceFiles.all(tree).values.map {
        (String(bytes: $0, encoding: .utf8) ?? "")
      }
      #expect(!text.contains { Self.masked($0, scratch) != $0 || $0.contains("/private/") })
    }
  }

  /// Separate processes, so a hash-seeded ordering would show, give identical bytes.
  @Test func separateProcessesWriteIdenticalBytes() throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      for root in ["a", "b"] {
        let result = try SiltaBinary.run(["--ws", "acme", "export", "--to", root], in: scratch)
        #expect(result.termination == .exit(0), "\(result.stderr)")
      }
      let first = try ExportServiceFiles.all(scratch.appending(path: "work/a/acme"))
      #expect(first.count == 7)
      #expect(first == (try ExportServiceFiles.all(scratch.appending(path: "work/b/acme"))))
    }
  }

  /// Enough tasks that writing a tree takes a while, so unserialised exports of one
  /// workspace would remove each other's staging directory.
  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func concurrentExportsOfOneWorkspaceAllSucceed() async throws {
    try await withScratchDirectory { scratch in
      try Self.seed(scratch)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      try await queue.write { db in
        for seq in 2...400 {
          try db.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
              VALUES(?,1,?,'Acme work','todo','human:acme','2023-11-14T22:00:00.000Z',
                '2023-11-14T22:00:00.000Z')
              """, arguments: ["01HZLOAD\(seq)", seq])
        }
      }
      let results = try await withThrowingTaskGroup(of: CLIResult.self) { group in
        for _ in 0..<8 {
          group.addTask {
            try SiltaBinary.run(["--ws", "acme", "export", "--to", "shared"], in: scratch)
          }
        }
        return try await group.reduce(into: []) { $0.append($1) }
      }
      for result in results { #expect(result.termination == .exit(0), "\(result.stderr)") }
      let reference = try SiltaBinary.run(["--ws", "acme", "export", "--to", "ref"], in: scratch)
      #expect(reference.termination == .exit(0))
      #expect(
        try ExportServiceFiles.all(scratch.appending(path: "work/shared/acme"))
          == (try ExportServiceFiles.all(scratch.appending(path: "work/ref/acme"))))
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: scratch.appending(path: "work/shared").path)
          == ["acme"])
    }
  }

  @Test func refusalOfANonExportTargetIsForTheHuman() throws {
    try withScratchDirectory { scratch in
      try Self.seed(scratch)
      let target = scratch.appending(path: "work/notes/acme")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data("Acme".utf8).write(to: target.appending(path: "README.md"))
      for json in [false, true] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "export", "--to", "notes"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(6))
        Golden.forTests().check(
          Self.masked(json ? result.stdout : result.stderr, scratch),
          json ? "export-target-refused.json" : "export-target-refused.txt")
      }
      #expect(try Data(contentsOf: target.appending(path: "README.md")) == Data("Acme".utf8))
    }
  }
}

enum ExportServiceFiles {
  /// Every regular file under `directory`, relative path to bytes.
  static func all(_ directory: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
      return files
    }
    for case let path as String in enumerator {
      var isDirectory: ObjCBool = false
      let url = directory.appending(path: path)
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        files[path] = try Data(contentsOf: url)
      }
    }
    return files
  }
}
