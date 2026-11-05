import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ExportServiceTests {
  static func export(_ store: DatabaseStore, _ home: URL, to root: URL) throws -> ExportResult {
    try ExportService.export(workspace: "acme", to: root, store: store, home: home)
  }

  /// Every regular file under `directory`, relative path to bytes.
  static func tree(_ directory: URL) throws -> [String: Data] {
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

  @Test func writesTheTreeAndReplacesAPreviousExport() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let first = try Self.export(store, home, to: root)
      let target = root.appending(path: "acme")
      #expect(first.workspace == "acme")
      #expect(first.files == 9)
      #expect(URL(filePath: first.path).standardizedFileURL == target.standardizedFileURL)
      ExportTreeTests.expectSame(try Self.tree(target), try ExportTreeTests.golden("acme"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE task SET seq=11 WHERE seq=10")
        try $0.execute(sql: "UPDATE seq_counter SET next=12 WHERE scope='task:1'")
      }
      try Data().write(to: target.appending(path: ".DS_Store"))
      _ = try Self.export(store, home, to: root)
      let second = try Self.tree(target)
      #expect(second["tasks/AC-10.md"] == nil)
      #expect(second["tasks/AC-11.md"] != nil)
      #expect(second[".DS_Store"] == nil)
      ExportTreeTests.expectSame(second, try ExportTreeTests.render(store))
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(leftovers == ["acme"])
    }
  }

  /// A directory that isn't exactly a previous export is never replaced.
  @Test(arguments: TargetShape.allCases)
  func refusesToReplaceWhatIsNotAnExport(_ shape: TargetShape) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let target = root.appending(path: "acme")
      if shape.startsFromExport { _ = try Self.export(store, home, to: root) }
      try shape.prepare(target)
      let before = try Self.tree(target)
      #expect(throws: ExportError.self) { try Self.export(store, home, to: root) }
      do {
        _ = try Self.export(store, home, to: root)
      } catch let error as ExportError {
        #expect(error.code == .conflict)
        #expect(error.nextBy == .human)
      }
      #expect(try Self.tree(target) == before)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }

  enum TargetShape: CaseIterable, CustomTestStringConvertible {
    case unrelatedDirectory, gitRepository, extraFile, plainFile, noFormatKey, otherWorkspace

    var testDescription: String { "\(self)" }

    var startsFromExport: Bool {
      switch self {
      case .extraFile, .noFormatKey, .otherWorkspace: true
      default: false
      }
    }

    func prepare(_ target: URL) throws {
      let fm = FileManager.default
      switch self {
      case .unrelatedDirectory:
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("Acme notes".utf8).write(to: target.appending(path: "README.md"))
      case .gitRepository:
        try fm.createDirectory(
          at: target.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: target.appending(path: ".git/HEAD"))
      case .extraFile:
        try Data("hand edit".utf8).write(to: target.appending(path: "tasks/NOTES.md"))
      case .otherWorkspace:
        let manifest = target.appending(path: "manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try Data(
          text.replacingOccurrences(of: #""workspace": "acme""#, with: #""workspace": "beta""#)
            .utf8
        ).write(to: manifest)
      case .plainFile:
        try fm.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: target)
      case .noFormatKey:
        try Data("{}\n".utf8).write(to: target.appending(path: "manifest.json"))
      }
    }
  }

  /// A previous export with a listed file deleted is still export's own tree.
  @Test func previousExportMissingAFileIsReplaced() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      _ = try Self.export(store, home, to: root)
      try FileManager.default.removeItem(at: root.appending(path: "acme/links.jsonl"))
      _ = try Self.export(store, home, to: root)
      ExportTreeTests.expectSame(
        try Self.tree(root.appending(path: "acme")), try ExportTreeTests.golden("acme"))
    }
  }

  /// A root outside every repo whose `<root>/<workspace>` is, or holds, a registered
  /// repo; an empty one would otherwise pass the target check and be swapped away.
  @Test(arguments: ["code/acme", "code/acme/api"])
  func targetThatIsARegisteredRepoIsRefused(_ repoPath: String) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let repo = scratch.appending(path: repoPath)
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: "UPDATE repo_path SET path=? WHERE repo_id=1",
          arguments: [try LocationPath.canonical(repo).path])
      }
      #expect(throws: ExportError.self) {
        try Self.export(store, home, to: scratch.appending(path: "code"))
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: repo.path).isEmpty)
    }
  }

  @Test func plainFileTargetIsLeftAlone() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      try TargetShape.plainFile.prepare(root.appending(path: "acme"))
      #expect(throws: ExportError.self) { try Self.export(store, home, to: root) }
      #expect(try Data(contentsOf: root.appending(path: "acme")) == Data("not a directory".utf8))
    }
  }

  @Test func rootInsideARegisteredRepoIsRefusedWithNothingCreated() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let repo = scratch.appending(path: "platform")
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: "UPDATE repo_path SET path=? WHERE repo_id=1",
          arguments: [try LocationPath.canonical(repo).path])
      }
      for root in [repo, repo.appending(path: "backups/silta")] {
        #expect(throws: ExportError.self) { try Self.export(store, home, to: root) }
        do {
          _ = try Self.export(store, home, to: root)
        } catch let error as ExportError {
          #expect(error.code == .invalid)
          #expect(error.nextBy == .human)
        }
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: repo.path).isEmpty)
    }
  }

  @Test func leftoverStagingFromACrashIsReplaced() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      let staging = root.appending(path: ".acme.staging")
      try FileManager.default.createDirectory(
        at: staging.appending(path: "tasks"), withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: staging.appending(path: "tasks/AC-99.md"))
      _ = try Self.export(store, home, to: root)
      ExportTreeTests.expectSame(
        try Self.tree(root.appending(path: "acme")), try ExportTreeTests.golden("acme"))
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }

  @Test func refusalWritesNothing() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "exports")
      _ = try Self.export(store, home, to: root)
      let before = try Self.tree(root.appending(path: "acme"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: """
            INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES('01HZDOC0000000000000000001',1,'auth','Auth','design','x','x')
            """)
      }
      #expect(throws: ExportError.unsupported("docs")) { try Self.export(store, home, to: root) }
      #expect(try Self.tree(root.appending(path: "acme")) == before)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["acme"])
    }
  }
}
