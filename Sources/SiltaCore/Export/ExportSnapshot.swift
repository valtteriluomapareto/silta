package import Foundation
package import GRDB

/// One exported row: its keys in format order, NULL columns left out (spec §15).
package struct ExportRow: Equatable, Sendable {
  /// Key and value pairs in the order they are written.
  package var fields: [Field]

  /// A key and its value as written.
  package struct Field: Equatable, Sendable {
    /// The column or reference name.
    package var key: String
    /// The stored text, or an integer in decimal.
    package var value: String

    /// Compares the literal UTF-8 bytes, not canonical equivalence.
    package static func == (left: Self, right: Self) -> Bool {
      left.key == right.key && left.value.utf8.elementsEqual(right.value.utf8)
    }
  }

  /// The value under `key`, or nil when the column was NULL.
  package func value(_ key: String) -> String? {
    fields.first { $0.key == key }?.value
  }
}

/// A task file pair: the task row (bodies included) and its jsonl records.
package struct ExportTask: Equatable, Sendable {
  /// The display ref that names the files.
  package var ref: String
  /// The task row, `ref` first.
  package var row: ExportRow
  /// Plan revisions, events, comments and review requests, `table` first.
  package var records: [ExportRow]
}

/// A workspace as format 1 holds it, independent of integer ids.
package struct ExportSnapshot: Equatable, Sendable {
  /// The last applied migration.
  package var schema: String
  /// The workspace row.
  package var workspace: ExportRow
  /// `workspace.yaml` sections in file order.
  package var sections: [Section]
  /// Tasks in id order.
  package var tasks: [ExportTask]
  /// `links.jsonl` rows.
  package var links: [ExportRow]
  /// `alias_decisions.jsonl` rows.
  package var aliasDecisions: [ExportRow]
  /// `approvals.jsonl` rows.
  package var approvals: [ExportRow]

  /// A named `workspace.yaml` section.
  package struct Section: Equatable, Sendable {
    /// The section name, e.g. `repos`.
    package var name: String
    /// Its rows in id order.
    package var rows: [ExportRow]
  }

  /// Reads the workspace named `slug` from one read transaction.
  package static func read(_ db: Database, workspace slug: String) throws -> Self {
    throw ExportError.unsupported("everything")
  }

  /// The tree's files keyed by relative path, `manifest.json` included.
  package func files() -> [String: Data] { [:] }
}
