import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Every refused restore leaves the database exactly as it was, in a dry run and in a
/// real run, and answers with the code its case names.
@Suite(.timeLimit(.minutes(1)))
struct RestoreRefusalTests {
  /// A damaged tree whose manifest is rehashed, so only restore's own checks see it.
  struct Damage: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let code: ErrorCode
    let apply: @Sendable (inout [String: Data]) -> Void

    init(
      _ name: String, _ code: ErrorCode, _ path: String, _ old: String, _ new: String,
      rehash: Bool = true
    ) {
      testDescription = name
      self.code = code
      apply = { files in
        files[path] = Data(
          text(files[path] ?? Data()).replacingOccurrences(of: old, with: new).utf8)
        if rehash { TreeDamage.rehash(&files, path) }
      }
    }
  }

  static let task2 = "01HZTASK000000000000000009"
  static let task10 = "01HZTASK000000000000000001"

  static let damages: [Damage] = [
    .init("flipped byte", .invalid, "tasks/AC-2.md", "Waiting.", "Waiting!", rehash: false),
    .init(
      "future format", .invalid, "manifest.json", #""format": "1""#, #""format": "2""#,
      rehash: false),
    .init(
      "newer schema", .env, "manifest.json", #""schema": "v7""#, #""schema": "v99""#,
      rehash: false),
    .init(
      "dangling parent", .invalid, "tasks/AC-10.md", #"parent: "\#(task2)""#,
      #"parent: "01HZTASKGONE""#),
    .init(
      "dangling thread", .invalid, "tasks/AC-2.jsonl", #""thread": "01HZCMNT000000000000000009""#,
      #""thread": "01HZCMNTGONE""#),
    .init(
      "dangling link end", .invalid, "links.jsonl", #""to": "01HZAPP0000000000000000009""#,
      #""to": "01HZAPPGONE""#),
    .init(
      "dangling app", .invalid, "workspace.yaml", #""app": "01HZAPP0000000000000000009""#,
      #""app": "01HZAPPGONE""#),
    .init(
      "priority not an integer", .invalid, "tasks/AC-2.md", #"priority: "1""#,
      #"priority: "high""#),
    .init("duplicate uid", .invalid, "tasks/AC-10.md", #"uid: "\#(task10)""#, #"uid: "\#(task2)""#),
    .init(
      "parent cycle", .invalid, "tasks/AC-2.md", #"app: "01HZAPP"#,
      #"parent: "\#(task10)"\#napp: "01HZAPP"#),
    .init(
      "uid of another workspace", .conflict, "workspace.yaml", "01HZSVC0000000000000000001",
      "01HZSVC00000000000000OTHR"),
    .init(
      "workspace uid of another workspace", .conflict, "workspace.yaml",
      "01HZACME00000000000000WS01", "01HZOTHR00000000000000WS02"),
    .init(
      "approval of another workspace", .conflict, "approvals.jsonl",
      "01HZAPRV000000000000000009", "01HZAPRV0000000000000OTHR"),
    .init(
      "duplicate app slug", .invalid, "workspace.yaml", #""slug": "api""#, #""slug": "portal""#),
    .init(
      "duplicate plan revision", .invalid, "tasks/AC-2.jsonl", #""rev": "1""#, #""rev": "2""#),
    .init(
      "unknown setting", .invalid, "workspace.yaml", #"{\"proposals\":\"ask\"}"#,
      #"{\"proposals\":\"ask\",\"colour\":\"red\"}"#),
    .init(
      "invalid setting value", .invalid, "workspace.yaml", #"{\"proposals\":\"ask\"}"#,
      #"{\"proposals\":\"maybe\"}"#),
    // Parses as an integer but doesn't survive storage: only the self-check sees it.
    .init(
      "value changed by storage", .invalid, "tasks/AC-2.md", #"priority: "1""#, #"priority: "01""#),
  ]

  @Test(arguments: damages, [false, true])
  func refusedRestoresChangeNothing(_ damage: Damage, dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      var files = try ExportTreeTests.render(store)
      damage.apply(&files)
      let tree = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      try RestoreSupport.settle(store)
      let dump = try RestoreSupport.dump(store)
      let backups = try RestoreSupport.backups(home)
      do {
        _ = try RestoreSupport.restore(tree, into: store, home: home, dryRun: dryRun)
        Issue.record("\(damage.testDescription) was restored")
      } catch let error as any CodedError {
        #expect(error.code == damage.code, "\(error.message)")
        #expect(error.nextBy == .human, "\(error.message)")
      }
      #expect(try RestoreSupport.dump(store) == dump)
      // Only a refusal found inside the transaction may leave its before-restore snapshot.
      let added = try RestoreSupport.backups(home).subtracting(backups)
      #expect(added.allSatisfy { $0.contains("-before-restore-") })
      if dryRun || damage.testDescription != "value changed by storage" { #expect(added.isEmpty) }
    }
  }

  @Test func newerDatabaseAndDocsAreRefused() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(
          sql: """
            INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES('01HZDOC0000000000000000001',1,'auth','Auth','design','x','x')
            """)
      }
      let docs = try RestoreSupport.dump(store)
      #expect(throws: ExportError.unsupported("docs")) {
        try RestoreSupport.restore(tree, into: store, home: home)
      }
      #expect(try RestoreSupport.dump(store) == docs)
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "DELETE FROM doc")
        try $0.execute(sql: "INSERT INTO grdb_migrations VALUES('v99')")
      }
      let newer = try RestoreSupport.dump(store)
      #expect(throws: StorageError.schemaTooNew) {
        try RestoreSupport.restore(tree, into: store, home: home)
      }
      #expect(try RestoreSupport.dump(store) == newer)
    }
  }

  @Test func inputsThatAreNotATreeAreRefused() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let root = scratch.appending(path: "tree")
      let tree = try RestoreSupport.exportTree(store, to: root)
      let dump = try RestoreSupport.dump(store)
      let backup = scratch.appending(path: "silta-2023-11-14.db")
      try Data("SQLite".utf8).write(to: backup)
      try FileManager.default.createSymbolicLink(
        at: tree.appending(path: "tasks/extra.md"), withDestinationURL: backup)
      for (input, hint) in [
        (backup, "a .db backup"), (root, "acme"),
        (scratch.appending(path: "absent"), "no such directory"),
        (tree, "symlink"),
      ] {
        do {
          _ = try RestoreSupport.restore(input, into: store, home: home)
          Issue.record("\(input.lastPathComponent) was restored")
        } catch let error as ExportError {
          #expect(error.code == .invalid)
          #expect(
            error.message.contains(hint) || error.next.joined().contains(hint), "\(error.message)")
          // Only the hint to a tree inside the root is a dry run the agent may run itself.
          #expect(error.nextBy == (hint == "acme" ? .agent : .human), "\(error.message)")
        }
      }
      #expect(try RestoreSupport.dump(store) == dump)
    }
  }

  @Test func prefixHeldByAnotherWorkspaceIsAConflict() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE workspace SET task_prefix='AX' WHERE slug='acme'")
        try $0.execute(sql: "UPDATE workspace SET task_prefix='AC' WHERE slug='other'")
      }
      let dump = try RestoreSupport.dump(store)
      do {
        _ = try RestoreSupport.restore(tree, into: store, home: home)
        Issue.record("restored over another workspace's prefix")
      } catch let error as ExportError {
        #expect(error.code == .conflict && error.nextBy == .human)
        #expect(error.message.contains("other"))
      }
      #expect(try RestoreSupport.dump(store) == dump)
    }
  }

  @Test func treeOfAnotherWorkspaceThanTheNamedOneIsRefused() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      do {
        _ = try RestoreSupport.restore(tree, into: store, home: home, workspace: "other")
        Issue.record("restored under another workspace")
      } catch let error as ExportError {
        #expect(error.code == .invalid && error.nextBy == .agent)
        #expect(error.next.first?.hasPrefix("silta --ws 'acme' restore ") == true)
      }
    }
  }
}
