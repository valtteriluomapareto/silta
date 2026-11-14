import Foundation
import GRDB

extension DocProposalInbox {
  func member(_ row: Row) throws -> DocProposalPreview {
    let source: Int64? = row["source_id"], owner: Int64? = row["source_owner"]
    guard source == nil || owner != nil else { throw StorageError.corrupt }
    let missing = (row["base_rev"] as Int?) != nil && (row["base_id"] as Int64?) == nil
    return DocProposalPreview(
      ref: text(row, "ref", reference: true), title: text(row, "title"), kind: text(row, "kind"),
      why: text(row, "why", missing: "(not recorded)"),
      sourceTask: text(row, "source", missing: "(not recorded)", reference: true),
      summary: summary(row), read: read(row["slug"], revision: row["rev"], missing: missing))
  }

  func text(_ row: Row, _ name: String, missing: String = "(unknown)", reference: Bool = false)
    -> String
  {
    let bytes: Int? = row[name + "_bytes"]
    if let bytes, bytes > 65_536 { return "(\(bytes) bytes omitted)" }
    guard let value: String = row[name] else { return missing }
    let masked = SecretGuard.redacted(reference ? DocService.about([value]) : value)
    let flat = masked.map { character in
      character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
        ? " " : String(character)
    }.joined()
    guard flat.count > 120 || flat.utf8.count > 512 else { return flat }
    let characters = Array(flat)
    var shown = min(120, characters.count)
    while shown > 0 {
      let candidate =
        String(characters.prefix(shown)) + " [\(characters.count - shown) characters omitted]"
      if candidate.count <= 120 && candidate.utf8.count <= 512 { return candidate }
      shown -= 1
    }
    return "[\(characters.count) characters omitted]"
  }

  private func summary(_ row: Row) -> String {
    let base: Int? = row["base_rev"], id: Int64? = row["base_id"]
    if base != nil && id == nil { return "recorded base unavailable" }
    let equal: Bool = row["body_equal"], old: Int = row["old_bytes"], new: Int = row["new_bytes"]
    var fields = [equal ? "body unchanged" : "body changed (\(old)→\(new) bytes)"]
    if base != nil {
      for name in ["title", "kind", "about"] {
        let changed: Bool? = row[name + "_change"]
        if changed == nil {
          fields.append(name + " unknown")
        } else if changed == true {
          fields.append(name + " changed")
        }
      }
    }
    return fields.joined(separator: "; ")
  }

  private var hub: String {
    guard WorkspaceConfig.isValidIdentifier(workspace), SecretGuard.matches(in: workspace).isEmpty
    else { return "silta ws ls" }
    let command = workspaceCommand("silta doc ls", workspace: workspace)
    return command.utf8.count <= 512 ? command : "silta ws ls"
  }

  private func safe(_ slug: String?) -> String? {
    guard hub != "silta ws ls", let slug, WorkspaceConfig.isValidIdentifier(slug),
      DocService.safeReference("doc:" + slug)
    else { return nil }
    return slug
  }

  private func read(_ slug: String?, revision: Int, missing: Bool) -> String {
    guard let slug = safe(slug) else { return hub }
    let command = workspaceCommand(
      "silta doc show " + shellWord("doc:\(slug)@\(revision)") + (missing ? "" : " --diff"),
      workspace: workspace)
    return command.utf8.count <= 512 ? command : hub
  }

  func page(_ slug: String?) throws -> String {
    guard let slug = safe(slug) else { return hub }
    let offset =
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM doc d JOIN doc_rev r ON r.doc_id=d.id
          WHERE d.workspace_id=? AND d.slug COLLATE BINARY<? COLLATE BINARY
            AND ((r.rev=d.current_rev AND r.state='accepted') OR r.state='proposed')
          """, arguments: [workspaceID, slug]) ?? 0
    let command = workspaceCommand(
      "silta doc ls --archived --offset \(offset) --limit 20", workspace: workspace)
    return command.utf8.count <= 512 ? command : hub
  }
}
