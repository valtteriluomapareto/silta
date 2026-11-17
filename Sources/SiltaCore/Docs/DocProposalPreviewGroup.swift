/// Bounded, masked evidence for one document proposal group.
package struct DocProposalPreviewGroup: Encodable, Sendable {
  let id: Int64
  let ref: String
  let total: Int
  let omitted: Int
  let members: [DocProposalPreview]
  let next: String?
  /// Bounded pinned members for direct document navigation.
  package var documentReferences: [String] { members.map(\.ref) }
  /// Masked display title of this document group.
  package var displayTitle: String? { members.first?.title }

  /// Masked author of the newest proposed revision.
  package var author: String? { members.first?.author }
  /// Immutable revision number of the newest proposal.
  package var revision: Int? { members.first?.revision }
  /// Recorded source task, when one was retained.
  package var sourceTask: String? {
    guard let ref = members.first?.sourceTask, ref != "(not recorded)" else { return nil }
    return ref
  }

  init(id: Int64, ref: String, total: Int, members: [DocProposalPreview], next: String?) {
    self.id = id
    self.ref = ref
    self.total = total
    omitted = total - members.count
    self.members = members
    self.next = next
  }

  enum CodingKeys: String, CodingKey { case ref, total, omitted, members, next }
}
