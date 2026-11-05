import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// `dogfood-report.sh --ws <slug>`: a private report for any workspace, written under
/// `$SILTA_HOME/reports/<slug>/` and never into a repository.
@Suite(.timeLimit(.minutes(2)))
struct DogfoodPrivateReportTests {
  typealias Report = DogfoodReportTests

  static func folder(_ scratch: URL, _ slug: String) -> URL {
    scratch.appending(path: "silta-home/reports/\(slug)")
  }

  /// A checkout holding a copy of the script, with a committed report.
  static func checkout(_ scratch: URL) throws -> (folder: URL, script: URL) {
    let folder = scratch.appending(path: "report-repo")
    let scripts = folder.appending(path: "scripts")
    let reports = folder.appending(path: "docs/dogfood/reports")
    for directory in [scripts, reports] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("Acme committed report".utf8).write(to: reports.appending(path: "2023-11-14.md"))
    let script = scripts.appending(path: "dogfood-report.sh")
    try FileManager.default.copyItem(
      at: Report.root.appending(path: "scripts/dogfood-report.sh"), to: script)
    return (folder, script)
  }

  static func files(under folder: URL) throws -> [String: Data] {
    let base = folder.path + "/"
    var files: [String: Data] = [:]
    let walker = FileManager.default.enumerator(atPath: folder.path)
    while let relative = walker?.nextObject() as? String {
      let path = base + relative
      var directory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue
      {
        files[relative] = FileManager.default.contents(atPath: path) ?? Data()
      }
    }
    return files
  }

  static func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  static func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  @Test func privateReportLandsUnderSiltaHomeAndNeverInTheRepository() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let checkout = try Self.checkout(scratch)
      let before = try Self.files(under: checkout.folder)
      let result = try Report.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools,
        script: checkout.script)
      let report = Self.folder(scratch, "silta").appending(path: "2023-11-30.md")
      #expect(result.termination == .exit(0))
      #expect(result.stdout == report.path + "\n")
      #expect(result.stderr.isEmpty)
      Golden.forTests().check(try Self.text(report), "dogfood-report.md")
      #expect(try Self.files(under: checkout.folder) == before)
      #expect(
        try Self.files(under: Self.folder(scratch, "silta")).keys.sorted() == ["2023-11-30.md"])
      #expect(try Self.permissions(Self.folder(scratch, "silta")) == 0o700)
      #expect(try Self.permissions(report) == 0o600)
    }
  }

  @Test func privateRangeStartsAtTheNewestPrivateReportNotTheCommittedOnes() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let checkout = try Self.checkout(scratch)
      let first = try Report.run(
        ["--ws", "silta"], scratch: scratch, tools: tools, script: checkout.script)
      let written = Self.folder(scratch, "silta").appending(path: "2023-11-30.md")
      #expect(first.termination == .exit(0))
      #expect(try Self.text(written).contains("Since: 1970-01-01 (UTC, inclusive)."))
      try FileManager.default.removeItem(at: written)
      for day in ["2023-11-13", "2023-11-14"] {
        try Data("Acme private report".utf8).write(
          to: Self.folder(scratch, "silta").appending(path: day + ".md"))
      }
      let next = try Report.run(
        ["--ws", "silta"], scratch: scratch, tools: tools, script: checkout.script)
      #expect(next.termination == .exit(0))
      Golden.forTests().check(try Self.text(written), "dogfood-report.md")
    }
  }

  @Test func reportOfTheSameDayIsNeverOverwritten() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let folder = Self.folder(scratch, "silta")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let existing = folder.appending(path: "2023-11-30.md")
      try Data("Acme reviewed report".utf8).write(to: existing)
      let result = try Report.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(result.stderr.contains(existing.path))
      #expect(try Self.text(existing) == "Acme reviewed report")
      #expect(try Self.files(under: folder).count == 1)
    }
  }

  @Test(arguments: [
    "", "-acme", "acme-", "_acme", "ac'me", "acme;touch pwned", "../acme", "acme/x", "a b",
    "acme\n", "--since",
  ])
  func invalidSlugIsRefusedBeforeAnyRead(slug: String) throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let marker = scratch.appending(path: "silta-called")
      try Report.tool(
        "silta", text: "#!/bin/bash\ntouch " + shellWord(marker.path) + "\nexit 9\n", in: tools)
      let result = try Report.run(["--ws", slug], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/reports").path))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "work/pwned").path))
    }
  }

  @Test(arguments: [["--ws"], ["--ws", "silta", "--ws", "acme"], ["--ws", "silta", "--since"]])
  func malformedArgumentsAreRefused(args: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let result = try Report.run(args, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(result.stderr.contains("usage:"))
    }
  }

  @Test func unknownWorkspaceWritesNothing() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let result = try Report.run(
        ["--ws", "globex", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/reports").path))
    }
  }

  @Test func canariesNeverCrossWorkspaces() throws {
    try withScratchDirectory { scratch in
      let store = try Report.setup(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE approval SET created_at='2023-11-14T12:00:00.000Z'
            WHERE uid='acme-foreign-approval';
            UPDATE task SET created_at='2023-11-01T00:00:00.000Z',
              updated_at='2023-11-14T00:00:00.000Z' WHERE uid='acme-foreign-task';
            """)
      }
      let tools = try Report.tools(scratch)
      let committed = try Report.run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
      let silta = try Report.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      let acme = try Report.run(
        ["--ws", "acme", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(committed.termination == .exit(0))
      #expect(silta.termination == .exit(0) && acme.termination == .exit(0))
      let siltaReport = try Self.text(
        Self.folder(scratch, "silta").appending(path: "2023-11-30.md"))
      let acmeReport = try Self.text(Self.folder(scratch, "acme").appending(path: "2023-11-30.md"))
      for report in [committed.stdout, siltaReport] {
        #expect(!report.contains("Acme foreign") && !report.contains("AC-1"))
      }
      #expect(acmeReport.contains("| Acme foreign command | 1 | 100% | env: 1 |"))
      #expect(acmeReport.contains("| 2023-W46 | other | 1 |"))
      #expect(
        acmeReport.contains(
          "## Friction in the acme workspace\n\nNot collected: `Friction:` lines and dogfood tasks"
            + " belong to the silta workspace only (D36).\n\n## Human load"))
      #expect(acmeReport.contains("Consecutive failures within the selected acme stream"))
      for canary in [
        "SI-", "Re-reading the Acme plan", "Acme command repair", "| silta task start |",
        "stale_context", "silta workspace\n", "| 2023-W47 |",
      ] {
        #expect(!acmeReport.contains(canary))
      }
      Golden.forTests().check(siltaReport, "dogfood-report.md")
      Golden.forTests().check(committed.stdout, "dogfood-report.md")
    }
  }
}
