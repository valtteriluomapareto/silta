import CryptoKit
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Hex SHA-256, computed here so manifest checks don't trust the exporter's own hashing.
enum SHA256Hex {
  static func of(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Proves from the live schema, not from the exporter's own column list, that every
/// column reaches the tree or is deliberately left out (spec §15).
@Suite(.timeLimit(.minutes(1)))
struct ExportCoverageTests {
  enum Column: Equatable {
    /// Written under the column name with its stored value.
    case plain
    /// A task body, written inside its fenced section.
    case body
    /// A foreign key, written as the target's uid under this key.
    case reference(String, table: String)
    /// A polymorphic link end, resolved through the kind column.
    case linkEnd(String, kind: String)
    /// Not written: an integer id, implied by the file, or machine-local.
    case excluded
  }

  static let tables: [String: [String: Column]] = [
    "workspace": [
      "id": .excluded, "uid": .plain, "slug": .plain, "name": .plain, "task_prefix": .plain,
      "settings": .plain,
    ],
    "repo": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "slug": .plain,
      "remote_url": .plain, "default_ref": .plain,
    ],
    "repo_path": ["repo_id": .excluded, "path": .excluded, "fetched_at": .excluded],
    "app": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "slug": .plain,
      "previous_slugs": .plain, "name": .plain, "repo_id": .reference("repo", table: "repo"),
      "ref": .plain, "prod_ref": .plain, "subpath": .plain, "is_primary": .plain,
      "stack": .plain, "summary": .plain, "lifecycle": .plain,
    ],
    "environment": [
      "id": .excluded, "uid": .plain, "app_id": .reference("app", table: "app"), "name": .plain,
      "url": .plain, "deploy": .plain, "notes": .plain,
    ],
    "service": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "slug": .plain, "name": .plain,
      "summary": .plain, "secrets_location": .plain,
    ],
    "edge": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded,
      "from_app_id": .reference("from_app", table: "app"),
      "to_app_id": .reference("to_app", table: "app"),
      "to_service_id": .reference("to_service", table: "service"), "kind": .plain,
      "summary": .plain, "code_refs": .plain,
    ],
    "topic": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "slug": .plain,
      "previous_slugs": .plain, "name": .plain, "summary": .plain, "status": .plain,
    ],
    "topic_alias": [
      "workspace_id": .excluded, "topic_id": .reference("topic", table: "topic"),
      "alias": .plain,
    ],
    "seq_counter": ["scope": .excluded, "next": .excluded],
    "task": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "seq": .plain,
      "title": .plain, "type": .plain, "status": .plain, "priority": .plain,
      "description_md": .body, "plan_md": .body, "plan_rev": .plain, "acceptance_md": .body,
      "result_md": .body, "parent_id": .reference("parent", table: "task"),
      "app_id": .reference("app", table: "app"), "claimed_by": .plain, "claimed_at": .plain,
      "branch": .plain, "worktree": .excluded, "done_sha": .plain, "done_branch": .plain,
      "done_dirty": .plain, "archive_override": .plain, "external_ref": .plain,
      "created_by": .plain, "created_at": .plain, "updated_at": .plain, "closed_at": .plain,
      "follow_up_at": .plain,
    ],
    "task_plan_rev": [
      "id": .excluded, "task_id": .excluded, "rev": .plain, "body_md": .plain,
      "actor": .plain, "created_at": .plain,
    ],
    "task_event": [
      "id": .excluded, "task_id": .excluded, "actor": .plain, "kind": .plain, "body": .plain,
      "created_at": .plain,
    ],
    "comment": [
      "id": .excluded, "uid": .plain, "task_id": .excluded, "doc_rev_id": .excluded,
      "seq": .plain, "thread_id": .reference("thread", table: "comment"), "kind": .plain,
      "verdict": .plain, "subject": .plain, "anchor": .plain, "anchor_sha": .plain,
      "anchor_snippet": .plain, "body_md": .plain, "mentions": .plain, "accepted": .plain,
      "actor": .plain, "resolved_at": .plain, "resolved_by": .plain, "deleted_at": .plain,
      "created_at": .plain,
    ],
    "review_request": [
      "id": .excluded, "task_id": .excluded, "reviewer": .plain, "subject": .plain,
      "requested_by": .plain, "created_at": .plain, "taken_by": .plain, "taken_at": .plain,
      "done_at": .plain,
    ],
    // Export refuses docs, so none of their columns are written.
    "doc": [
      "id": .excluded, "uid": .excluded, "workspace_id": .excluded, "slug": .excluded,
      "previous_slugs": .excluded, "title": .excluded, "kind": .excluded, "owner": .excluded,
      "current_rev": .excluded, "verified_at": .excluded, "archived": .excluded,
      "created_at": .excluded, "updated_at": .excluded,
    ],
    "doc_rev": [
      "id": .excluded, "uid": .excluded, "doc_id": .excluded, "rev": .excluded,
      "base_rev": .excluded, "body_md": .excluded, "state": .excluded, "actor": .excluded,
      "message": .excluded, "created_at": .excluded,
    ],
    "link": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "from_kind": .plain,
      "from_id": .linkEnd("from", kind: "from_kind"), "rel": .plain, "to_kind": .plain,
      "to_id": .linkEnd("to", kind: "to_kind"), "to_ext": .plain, "created_by": .plain,
      "created_at": .plain, "anchor": .plain,
    ],
    "alias_decision": [
      "workspace_id": .excluded, "note_ref": .plain,
      "topic_id": .reference("topic", table: "topic"), "decision": .plain, "actor": .plain,
      "created_at": .plain,
    ],
    "source": [
      "id": .excluded, "uid": .plain, "workspace_id": .excluded, "kind": .plain,
      "root": .plain, "include": .plain, "exclude": .plain,
      "repo_id": .reference("repo", table: "repo"),
    ],
    "worktree_override": ["path": .excluded, "app_id": .excluded, "set_by": .excluded],
    "approval": [
      "id": .excluded, "uid": .plain, "workspace": .excluded, "actor": .plain,
      "command": .plain, "words": .plain, "created_at": .plain,
    ],
    "meta": ["key": .excluded, "value": .excluded],
    "change_log": ["seq": .excluded, "kind": .excluded, "row_id": .excluded],
    "grdb_migrations": ["identifier": .excluded],
  ]

  /// The Acme rows of each table that carries data into the tree.
  static let scope: [String: String] = [
    "workspace": "id=1", "repo": "workspace_id=1", "app": "workspace_id=1",
    "environment": "app_id IN (SELECT id FROM app WHERE workspace_id=1)",
    "service": "workspace_id=1", "edge": "workspace_id=1", "topic": "workspace_id=1",
    "topic_alias": "workspace_id=1", "task": "workspace_id=1",
    "task_plan_rev": "task_id IN (SELECT id FROM task WHERE workspace_id=1)",
    "task_event": "task_id IN (SELECT id FROM task WHERE workspace_id=1)",
    "comment": "task_id IN (SELECT id FROM task WHERE workspace_id=1)",
    "review_request": "task_id IN (SELECT id FROM task WHERE workspace_id=1)",
    "link": "workspace_id=1", "alias_decision": "workspace_id=1", "source": "workspace_id=1",
    "approval": "workspace='acme'",
  ]

  static let kindTables = ["task": "task", "comment": "comment", "app": "app", "topic": "topic"]

  @Test func everyLiveColumnIsClassified() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      try store.read { db in
        let tables = try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        #expect(Set(tables) == Set(Self.tables.keys))
        for table in tables {
          let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map {
            $0["name"] as String
          }
          #expect(Set(columns) == Set(Self.tables[table]?.keys ?? [:].keys), "\(table)")
        }
      }
    }
  }

  /// The fixture sets every exportable column in some Acme row; each stored value must
  /// appear in the tree under its key.
  @Test func everyExportedValueReachesTheTree() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      let text = files.values.map { (String(bytes: $0, encoding: .utf8) ?? "") }.joined(
        separator: "\n")
      try store.read { db in
        for (table, filter) in Self.scope {
          let columns = try #require(Self.tables[table])
          let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(filter)")
          #expect(!rows.isEmpty, "\(table)")
          for (column, kind) in columns where kind != .excluded {
            let values = rows.compactMap { $0[column] as DatabaseValue? }.filter { !$0.isNull }
            #expect(!values.isEmpty, "the fixture leaves \(table).\(column) NULL in every row")
            for (row, value) in zip(rows, rows.map { $0[column] as DatabaseValue })
            where !value.isNull {
              let expected = try Self.expected(kind, column: column, value: value, row: row, db: db)
              #expect(
                expected.contains { text.contains($0) },
                "\(table).\(column) value missing; looked for \(expected)")
            }
          }
        }
      }
    }
  }

  @Test func otherWorkspacesAndMachinePathsStayOut() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      let text = files.values.map { (String(bytes: $0, encoding: .utf8) ?? "") }.joined()
      for absent in ExportFixture.machinePaths + [
        "/private/", "Other work", "01HZTASK0000000000000OTHR", "01HZAPRV0000000000000NULL",
        "01HZAPRV0000000000000OTHR", "01HZOTHR00000000000000WS02",
      ] {
        #expect(!text.contains(absent), "\(absent)")
      }
    }
  }

  static func expected(
    _ kind: Column, column: String, value: DatabaseValue, row: Row, db: Database
  ) throws -> [String] {
    func quoted(_ text: String) -> String {
      "\""
        + text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    func keyed(_ key: String, _ text: String) -> [String] {
      ["\"\(key)\": \(quoted(text))", "\n\(key): \(quoted(text))\n"]
    }
    let text: String =
      switch value.storage {
      case .int64(let number): String(number)
      case .string(let string): string
      default: "\(value)"
      }
    switch kind {
    case .plain: return keyed(column, text)
    case .body: return ["\n" + text + "\n"]
    case .reference(let key, let table):
      let uid = try String.fetchOne(
        db, sql: "SELECT uid FROM \(table) WHERE id=?", arguments: [value])
      return keyed(key, try #require(uid))
    case .linkEnd(let key, let kindColumn):
      let kind: String = row[kindColumn]
      if kind == "task_plan_rev" {
        let task = try #require(
          try Row.fetchOne(
            db,
            sql:
              "SELECT task.uid, rev FROM task_plan_rev JOIN task ON task.id=task_id WHERE task_plan_rev.id=?",
            arguments: [value]))
        return [
          "\"\(key)\": \(quoted(task[0])), \"\(key)_rev\": \(quoted(String(task[1] as Int64)))"
        ]
      }
      let table = try #require(Self.kindTables[kind])
      let uid = try String.fetchOne(
        db, sql: "SELECT uid FROM \(table) WHERE id=?", arguments: [value])
      return keyed(key, try #require(uid))
    case .excluded: return []
    }
  }
}
