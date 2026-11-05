import Foundation

/// Format 1 keys and layout (spec §15), shared by rendering and the reader.
enum ExportFormat {
  static let version = "1"

  static let workspaceKeys = ["uid", "slug", "name", "task_prefix", "settings", "next_task_seq"]

  /// A `workspace.yaml` section: its name, the table its rows come from, and its keys.
  struct Section {
    let name: String
    let table: String
    let keys: [String]

    init(_ name: String, _ table: String, _ keys: [String]) {
      self.name = name
      self.table = table
      self.keys = keys
    }
  }

  /// `workspace.yaml` sections in file order.
  static let sections: [Section] = [
    Section("repos", "repo", ["uid", "slug", "remote_url", "default_ref"]),
    Section(
      "apps", "app",
      [
        "uid", "slug", "previous_slugs", "name", "repo", "ref", "prod_ref", "subpath",
        "is_primary", "stack", "summary", "lifecycle",
      ]
    ),
    Section("environments", "environment", ["uid", "app", "name", "url", "deploy", "notes"]),
    Section("services", "service", ["uid", "slug", "name", "summary", "secrets_location"]),
    Section(
      "edges", "edge",
      ["uid", "from_app", "to_app", "to_service", "kind", "summary", "code_refs"]
    ),
    Section("topics", "topic", ["uid", "slug", "previous_slugs", "name", "summary", "status"]),
    Section("topic_aliases", "topic_alias", ["topic", "alias"]),
    Section("sources", "source", ["uid", "kind", "root", "include", "exclude", "repo"]),
  ]

  static let taskKeys = [
    "ref", "uid", "seq", "title", "type", "status", "priority", "description_md", "plan_md",
    "plan_rev", "acceptance_md", "result_md", "parent", "app", "claimed_by", "claimed_at",
    "branch", "done_sha", "done_branch", "done_dirty", "archive_override", "external_ref",
    "created_by", "created_at", "updated_at", "closed_at", "follow_up_at",
  ]

  /// Task bodies in section order, with their headings; `result_md` may be absent.
  static let bodies: [(key: String, heading: String)] = [
    ("description_md", "Description"), ("plan_md", "Plan"), ("acceptance_md", "Acceptance"),
    ("result_md", "Result"),
  ]

  /// `tasks/<ref>.jsonl` record tables in file order, with their keys.
  static let records: [(table: String, keys: [String])] = [
    ("task_plan_rev", ["table", "rev", "body_md", "actor", "created_at"]),
    ("task_event", ["table", "actor", "kind", "body", "created_at"]),
    (
      "comment",
      [
        "table", "uid", "seq", "thread", "kind", "verdict", "subject", "anchor", "anchor_sha",
        "anchor_snippet", "body_md", "mentions", "accepted", "actor", "resolved_at",
        "resolved_by", "deleted_at", "created_at",
      ]
    ),
    (
      "review_request",
      [
        "table", "reviewer", "subject", "requested_by", "created_at", "taken_by", "taken_at",
        "done_at",
      ]
    ),
  ]

  static let linkKeys = [
    "uid", "from_kind", "from", "rel", "to_kind", "to", "to_rev", "to_ext", "created_by",
    "created_at", "anchor",
  ]

  static let aliasDecisionKeys = ["note_ref", "topic", "decision", "actor", "created_at"]

  static let approvalKeys = ["uid", "actor", "command", "words", "created_at"]

  static let workspaceFile = "workspace.yaml"
  static let linksFile = "links.jsonl"
  static let aliasDecisionsFile = "alias_decisions.jsonl"
  static let approvalsFile = "approvals.jsonl"
  static let manifestFile = "manifest.json"

  /// A double-quoted scalar, valid as JSON and as YAML: only `"`, `\`, controls and the
  /// characters YAML treats as line breaks or non-printable are escaped.
  static func quote(_ text: String) -> String {
    var output = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{0}"..."\u{1F}", "\u{7F}"..."\u{9F}", "\u{2028}", "\u{2029}", "\u{FEFF}",
        "\u{FFFE}", "\u{FFFF}":
        output += String(format: "\\u%04X", scalar.value)
      default: output.unicodeScalars.append(scalar)
      }
    }
    return output + "\""
  }

  /// `{"key": "value", …}`.
  static func line(_ row: ExportRow) -> String {
    "{" + row.fields.map { quote($0.key) + ": " + quote($0.value) }.joined(separator: ", ") + "}"
  }

  /// One row per line, each ending with a newline; empty for no rows.
  static func jsonl(_ rows: [ExportRow]) -> String {
    rows.map { line($0) + "\n" }.joined()
  }
}
