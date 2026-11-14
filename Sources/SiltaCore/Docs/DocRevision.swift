/// Immutable revision content; absent metadata means the historical value is unknown.
struct DocRevision: Sendable {
  let slug: String
  let revision: Int
  let baseRevision: Int?
  let body: String
  let title: String?
  let kind: String?
  let about: [String]?
  let state: String
  let actor: String
  let message: String?
  let createdAt: String
  let sourceTask: String?
  let triagedBy: String?
  let triagedAt: String?
}
