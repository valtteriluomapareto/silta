struct DocProposalPreview: Encodable, Sendable {
  let ref: String
  let author: String
  let revision: Int
  let title: String
  let kind: String
  let why: String
  let sourceTask: String
  let summary: String
  let staleBase: Bool
  let read: String
  let decisions: [String]

  enum CodingKeys: String, CodingKey {
    case ref, title, kind, why, summary, read
    case sourceTask = "source_task"
    case staleBase = "stale_base"
  }
}
