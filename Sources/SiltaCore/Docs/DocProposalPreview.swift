struct DocProposalPreview: Encodable, Sendable {
  let ref: String
  let title: String
  let kind: String
  let why: String
  let sourceTask: String
  let summary: String
  let read: String

  enum CodingKeys: String, CodingKey {
    case ref, title, kind, why, summary, read
    case sourceTask = "source_task"
  }
}
