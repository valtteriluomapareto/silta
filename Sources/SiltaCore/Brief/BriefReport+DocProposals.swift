extension BriefReport {
  mutating func hydrateDocProposals(_ inbox: DocProposalInbox) throws {
    let groups = sections.compactMap(\.docProposalGroup)
    let previews = try inbox.previews(groups)
    let byID = Dictionary(previews.map { ($0.id, $0) }) { first, _ in first }
    var emitted: Set<String> = []
    for index in sections.indices {
      guard let group = sections[index].docProposalGroup else { continue }
      guard let preview = byID[group.id] else { throw StorageError.corrupt }
      let commands = preview.commands.filter { emitted.insert($0).inserted }
      sections[index].text = preview.render(next: commands)
      sections[index].docProposalGroup = nil
    }
  }
}
