struct DocProposalPreviewGroup: Encodable, Sendable {
  let id: Int64
  let ref: String
  let total: Int
  let omitted: Int
  let members: [DocProposalPreview]
  let next: String?

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
