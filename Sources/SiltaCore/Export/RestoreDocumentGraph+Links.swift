import Foundation

extension RestoreDocumentGraph {
  func links() throws {
    var identities: Set<[String]> = []
    for link in tree.links {
      guard ["task", "doc", "comment"].contains(link.value("from_kind") ?? ""),
        let kind = link.value("to_kind"), link.value("uid") != nil,
        link.value("rel") != nil, link.value("created_by") != nil, link.value("created_at") != nil
      else { throw invalid("a link has an unknown source kind or missing metadata") }
      if ExportLinks.tables[kind] != nil {
        guard link.value("to") != nil, link.value("to_ext") == nil else {
          throw invalid("an owned link target is not a UID")
        }
      } else {
        guard ["note", "url", "code", "ext"].contains(kind),
          let external = link.value("to_ext"), !external.isEmpty, link.value("to") == nil
        else { throw invalid("a link has an unknown or missing external target") }
        do {
          if kind == "code" { _ = try TaskLinkTarget.storedCodeApp(external) }
          if kind == "url" { _ = try TaskLinkTarget.url("url:" + external) }
        } catch { throw invalid("a stored external reference has an invalid shape") }
      }
      if link.value("from_kind") == "doc", link.value("rel") == "about",
        !["app", "edge", "service", "topic"].contains(kind)
      {
        throw invalid("a live document about link must name a map identity")
      }
      let identity =
        ["from_kind", "from", "rel", "to_kind"].map { link.value($0) ?? "" }
        + [link.value("to") ?? link.value("to_ext") ?? "", link.value("anchor") ?? ""]
      guard identities.insert(identity).inserted else {
        throw invalid("a typed link identity appears twice")
      }
    }
  }
}
