extension ExportFormat {
  static let docKeys = [
    "uid", "slug", "previous_slugs", "title", "kind", "owner", "current_rev", "verified_at",
    "archived", "created_at", "updated_at",
  ]

  /// Document records in file order; revision bodies are carried by the Markdown file.
  static let docRecords: [(table: String, keys: [String])] = [
    (
      "doc_rev",
      [
        "table", "uid", "rev", "base_rev", "body_md", "state", "actor", "message", "created_at",
        "title", "kind", "about_refs", "source_task", "triaged_at", "triaged_by",
      ]
    ),
    (
      "doc_verification",
      ["table", "uid", "doc_rev", "actor", "message", "app_shas", "created_at"]
    ),
    (
      "comment",
      [
        "table", "uid", "doc_rev", "seq", "thread", "kind", "verdict", "subject", "anchor",
        "anchor_sha", "anchor_snippet", "body_md", "mentions", "accepted", "actor",
        "resolved_at", "resolved_by", "deleted_at", "created_at",
      ]
    ),
  ]
}
