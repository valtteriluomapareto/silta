import Foundation
import GRDB

extension DocProposalInbox {
  func member(_ row: Row, caller: ActorID) throws -> DocProposalPreview {
    let source: Int64? = row["source_id"]
    let owner: Int64? = row["source_owner"]
    guard source == nil || owner != nil else { throw StorageError.corrupt }
    let missing = (row["base_rev"] as Int?) != nil && (row["base_id"] as Int64?) == nil
    let stale: Bool = row["stale_base"]
    return DocProposalPreview(
      ref: try text(row, "ref", reference: true), title: try text(row, "title"),
      kind: try text(row, "kind"),
      why: try text(row, "why", missing: "(not recorded)"),
      sourceTask: try text(row, "source", missing: "(not recorded)", reference: true),
      summary: summary(row) + (stale ? "; stale base" : ""), staleBase: stale,
      read: read(try row.strictText("slug"), revision: row["rev"], missing: missing),
      decisions: decisions(
        try row.strictText("slug"), revision: row["rev"], rejectOnly: stale || missing,
        caller: caller))
  }

  func text(_ row: Row, _ name: String, missing: String = "(unknown)", reference: Bool = false)
    throws -> String
  {
    let bytes: Int? = row[name + "_bytes"]
    if let bytes, bytes > 65_536 { return "(\(bytes) bytes omitted)" }
    guard let value = try row.strictText(name) else { return missing }
    let masked = SecretGuard.redacted(reference ? DocService.about([value]) : value)
    let flat = masked.map { character in
      character.unicodeScalars.allSatisfy {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
      }
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
    let base: Int? = row["base_rev"]
    let id: Int64? = row["base_id"]
    if base != nil && id == nil { return "recorded base unavailable" }
    let equal: Bool = row["body_equal"]
    let old: Int = row["old_bytes"]
    let new: Int = row["new_bytes"]
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
    let command = workspaceCommand("silta doc ls --archived", workspace: workspace)
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

  private func decisions(
    _ slug: String?, revision: Int, rejectOnly: Bool, caller: ActorID
  ) -> [String] {
    guard let slug = safe(slug) else { return [hub] }
    let ref = "doc:\(slug)@\(revision)"
    let command = workspaceCommand("silta doc triage", workspace: workspace)
    let reject = command + " --reject " + shellWord(ref)
    let actions = rejectOnly ? [reject] : [command + " --accept " + shellWord(ref), reject]
    guard actions.allSatisfy({ $0.utf8.count <= 512 }) else { return [hub] }
    if caller.isHuman { return actions }
    let instruction =
      "ask human: " + (rejectOnly ? "Reject " : "Accept or reject ") + ref
      + "? After approval: "
      + actions.map { $0 + " --approved \"<the human's words>\"" }.joined(separator: "; or ")
    return instruction.utf8.count <= 512 ? [instruction] : [hub]
  }

  func page(_ slug: String?) -> String {
    guard let slug = safe(slug) else { return hub }
    let command = DocService.listPageCommand(
      workspace: workspace, about: nil,
      archived: true, offset: 0, limit: 20, document: slug)
    return command.utf8.count <= 512 ? command : hub
  }
}
