import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportTreeTests {
  static func render(_ store: DatabaseStore, _ slug: String = "acme") throws -> [String: Data] {
    try store.read { try ExportTree.render($0, workspace: slug) }
  }

  /// The hand-written tree under `Golden/export/<name>`, which `SILTA_UPDATE_GOLDENS`
  /// never rewrites: these files were written from spec §15, not from the code.
  static func golden(_ name: String) throws -> [String: Data] {
    let root = Golden.forTests().directory.appending(path: "export/\(name)")
    var files: [String: Data] = [:]
    let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
    for case let path as String in enumerator {
      var isDirectory: ObjCBool = false
      let url = root.appending(path: path)
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        files[path] = try Data(contentsOf: url)
      }
    }
    return files
  }

  static func expectSame(
    _ actual: [String: Data], _ expected: [String: Data],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.keys.sorted() == expected.keys.sorted(), sourceLocation: sourceLocation)
    for (path, bytes) in expected.sorted(by: { $0.key < $1.key }) {
      guard let got = actual[path], got != bytes else { continue }
      let gotLines = text(got).split(
        separator: "\n", omittingEmptySubsequences: false)
      let wantLines = text(bytes).split(
        separator: "\n", omittingEmptySubsequences: false)
      let index =
        (0..<min(gotLines.count, wantLines.count)).first { gotLines[$0] != wantLines[$0] }
        ?? min(gotLines.count, wantLines.count)
      Issue.record(
        """
        \(path) differs at line \(index + 1):
        expected: \(index < wantLines.count ? String(wantLines[index]) : "<end>")
        actual:   \(index < gotLines.count ? String(gotLines[index]) : "<end>")
        """, sourceLocation: sourceLocation)
    }
  }

  @Test func treeMatchesTheSpecGrammar() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      Self.expectSame(try Self.render(store), try Self.golden("acme"))
    }
  }

  @Test func emptyWorkspaceWritesEveryFile() throws {
    try withScratchDirectory { scratch in
      let store = ExportFixture.store(scratch)
      try store.initialize()
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('01HZBETA00000000000000WS03','beta','Beta','BE')
            """)
      }
      Self.expectSame(try Self.render(store, "beta"), try Self.golden("empty"))
    }
  }

  /// The same rows under other integer ids, inserted after unrelated rows, give the
  /// same bytes; uid order differs from id order in the fixture, so ordering by uid
  /// would fail the golden instead.
  @Test func bytesDependOnRowsNotIntegerIDs() throws {
    try withScratchDirectory { scratch in
      let first = try ExportFixture.make(scratch.appending(path: "a"))
      let shifted = try ExportFixture.make(scratch.appending(path: "b"), offset: 100)
      #expect(
        try shifted.read { try Int64.fetchOne($0, sql: "SELECT id FROM task WHERE seq=2") }
          == 101)
      Self.expectSame(try Self.render(shifted), try Self.render(first))
      Self.expectSame(try Self.render(first), try Self.render(first))
    }
  }

  @Test func manifestListsEveryFileWithItsHashAndCountsMatchTheDatabase() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try Self.render(store)
      let manifestBytes = try #require(files["manifest.json"])
      let manifest = try #require(
        try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
      let listed = try #require(manifest["files"] as? [[String: String]])
      #expect(
        Set(listed.compactMap { $0["path"] }) == Set(files.keys).subtracting(["manifest.json"]))
      for entry in listed {
        let path = try #require(entry["path"])
        let digest = SHA256Hex.of(try #require(files[path]))
        #expect(entry["sha256"] == digest, "\(path)")
      }
      let counts = try #require(manifest["counts"] as? [String: String])
      let scoped: [String: String] = [
        "workspace": "SELECT count(*) FROM workspace WHERE id=1",
        "repo": "SELECT count(*) FROM repo WHERE workspace_id=1",
        "app": "SELECT count(*) FROM app WHERE workspace_id=1",
        "environment":
          "SELECT count(*) FROM environment JOIN app ON app.id=app_id WHERE workspace_id=1",
        "service": "SELECT count(*) FROM service WHERE workspace_id=1",
        "edge": "SELECT count(*) FROM edge WHERE workspace_id=1",
        "topic": "SELECT count(*) FROM topic WHERE workspace_id=1",
        "topic_alias": "SELECT count(*) FROM topic_alias WHERE workspace_id=1",
        "source": "SELECT count(*) FROM source WHERE workspace_id=1",
        "task": "SELECT count(*) FROM task WHERE workspace_id=1",
        "task_plan_rev": Self.perTask("task_plan_rev"),
        "task_event": Self.perTask("task_event"),
        "comment": Self.perTask("comment"),
        "review_request": Self.perTask("review_request"),
        "link": "SELECT count(*) FROM link WHERE workspace_id=1",
        "alias_decision": "SELECT count(*) FROM alias_decision WHERE workspace_id=1",
        "approval": "SELECT count(*) FROM approval WHERE workspace='acme'",
      ]
      #expect(Set(counts.keys) == Set(scoped.keys))
      try store.read { db in
        for (table, sql) in scoped {
          let count = try Int.fetchOne(db, sql: sql) ?? -1
          #expect(counts[table] == String(count), "\(table)")
        }
      }
    }
  }

  static func perTask(_ table: String) -> String {
    "SELECT count(*) FROM \(table) WHERE task_id IN (SELECT id FROM task WHERE workspace_id=1)"
  }

  /// Values that YAML 1.1 or a naive emitter would change come back byte for byte.
  @Test func escapingCorpusRoundTrips() throws {
    let corpus = [
      "quote \" and backslash \\", "line\nbreak", "crlf\r\nend", "tab\there", "soh\u{1}x",
      "del\u{7F}", "c1\u{9F}", "nel\u{85}", "ls\u{2028}ps\u{2029}", "bom\u{FEFF}",
      "nonchar\u{FFFE}\u{FFFF}",
      "emoji 🧭", "no", "on", "0123", "~", "- [ ] item", "e\u{301}", "#comment", "{a: b}",
      "/slash/",
    ]
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      try DatabaseQueue(path: store.path).write { db in
        for (index, value) in corpus.enumerated() {
          try db.execute(
            sql: """
              INSERT INTO approval(uid,workspace,actor,command,words,created_at)
              VALUES(?,'acme','agent:codex:acme','silta ws edit',?,'2023-11-15T00:00:00.000Z')
              """, arguments: ["01HZCORP\(index)", value])
        }
        try db.execute(
          sql: "UPDATE task SET title=?, plan_md=? WHERE seq=2",
          arguments: [corpus.joined(separator: "|"), corpus.joined(separator: "\n")])
      }
      let files = try Self.render(store)
      let lines = text(try #require(files["approvals.jsonl"]))
        .split(separator: "\n")
      #expect(lines.count == corpus.count + 2)
      for (index, line) in lines.dropFirst(2).enumerated() {
        let object = try #require(
          try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        #expect(object["words"]?.utf8.elementsEqual(corpus[index].utf8) == true, "\(corpus[index])")
        #expect(!line.contains("\u{2028}") && !line.contains("\u{85}") && !line.contains("\u{1}"))
      }
      let raw = text(try #require(files["approvals.jsonl"]))
      for scalar in [
        "\u{1}", "\u{7F}", "\u{85}", "\u{9F}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{FFFE}",
        "\u{FFFF}", "\r", "\t",
      ] as [Unicode.Scalar] {
        #expect(
          !raw.unicodeScalars.contains(scalar), "U+\(String(scalar.value, radix: 16)) unescaped")
      }
      for spelled in [#"ls\u2028ps\u2029"#, #"bom\uFEFF"#, #"c1\u009F"#, #"crlf\r\nend"#] {
        #expect(raw.contains(spelled), "\(spelled)")
      }
      let snapshot = try ExportTree.parse(files)
      let task = try #require(snapshot.tasks.first { $0.ref == "AC-2" })
      #expect(
        task.row.value("title")?.utf8.elementsEqual(corpus.joined(separator: "|").utf8) == true)
      #expect(
        task.row.value("plan_md")?.utf8.elementsEqual(corpus.joined(separator: "\n").utf8) == true)
      Self.expectSame(snapshot.files(), files)
    }
  }

  @Test func docsAreRefusedRatherThanDropped() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: """
            INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES('01HZDOC0000000000000000001',1,'auth','Auth','design','x','x')
            """)
      }
      #expect(throws: ExportError.unsupported("docs")) { try Self.render(store) }
    }
  }

  @Test func unknownLinkKindsAreRefused() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE link SET to_kind='doc_rev' WHERE to_kind='app'")
      }
      #expect(throws: ExportError.unsupported("doc_rev links")) { try Self.render(store) }
    }
  }

  @Test func newerSchemaIsRefused() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "INSERT INTO grdb_migrations VALUES('v99')")
        try $0.execute(sql: "ALTER TABLE task ADD COLUMN estimate TEXT")
      }
      #expect(throws: StorageError.schemaTooNew) { try Self.render(store) }
    }
  }
}

/// Decodes UTF-8 test output, empty when it isn't UTF-8.
func text(_ data: Data) -> String {
  String(bytes: data, encoding: .utf8) ?? ""
}

/// One way a tree can differ from what export writes.
struct TreeDamage: Sendable, CustomTestStringConvertible {
  let testDescription: String
  let apply: @Sendable (inout [String: Data]) -> Void

  /// Replaces `old` with `new` in `path`; with `rehash`, the manifest is updated to
  /// match, so the reader must find the damage in the file itself.
  static func edit(
    _ name: String, _ path: String, _ old: String, _ new: String, rehash: Bool = true
  )
    -> Self
  {
    Self(testDescription: name) { files in
      files[path] = Data(text(files[path] ?? Data()).replacingOccurrences(of: old, with: new).utf8)
      if rehash { Self.rehash(&files, path) }
    }
  }

  static let all: [Self] = [
    edit("flipped byte", "tasks/AC-2.md", "Waiting.", "Waiting!", rehash: false),
    Self(testDescription: "missing file") { $0["tasks/AC-10.jsonl"] = nil },
    Self(testDescription: "extra file") { $0["tasks/AC-11.md"] = Data("---\n---\n".utf8) },
    Self(testDescription: "missing manifest") { $0["manifest.json"] = nil },
    edit(
      "reordered keys", "approvals.jsonl",
      #"{"uid": "01HZAPRV000000000000000009", "actor": "agent:codex:acme""#,
      #"{"actor": "agent:codex:acme", "uid": "01HZAPRV000000000000000009""#),
    edit("unknown key", "links.jsonl", #""rel": "cites""#, #""rel": "cites", "note": "x""#),
    edit("number value", "tasks/AC-2.md", #"priority: "1""#, "priority: 1"),
    edit("missing newline", "approvals.jsonl", "\"}\n{", "\"}{"),
    edit("extra blank line", "workspace.yaml", "sources:\n", "\nsources:\n"),
    edit("crlf", "tasks/AC-10.jsonl", "\n", "\r\n"),
    edit("wrong ref", "tasks/AC-2.md", #"ref: "AC-2""#, #"ref: "AC-3""#),
    edit("unquoted frontmatter", "tasks/AC-10.md", #"type: "chore""#, "type: chore"),
    edit("future format", "manifest.json", #""format": "2""#, #""format": "3""#, rehash: false),
    edit("escaped slash", "workspace.yaml", "src/Portal", #"src\/Portal"#),
    edit("wider fence", "tasks/AC-2.md", "~~~\nWaiting.\n~~~", "~~~~\nWaiting.\n~~~~"),
    Self(testDescription: "record groups out of order") { files in
      let lines = text(files["tasks/AC-2.jsonl"] ?? Data()).split(separator: "\n")
      files["tasks/AC-2.jsonl"] = Data((lines.reversed().joined(separator: "\n") + "\n").utf8)
      rehash(&files, "tasks/AC-2.jsonl")
    },
  ]

  static func rehash(_ files: inout [String: Data], _ path: String) {
    guard let manifest = files["manifest.json"], let bytes = files[path] else { return }
    var text = text(manifest)
    if let range = text.range(of: #"{"path": "\#(path)", "sha256": ""#) {
      let start = range.upperBound
      let end = text.index(start, offsetBy: 64)
      text.replaceSubrange(start..<end, with: SHA256Hex.of(bytes))
    }
    files["manifest.json"] = Data(text.utf8)
  }
}
