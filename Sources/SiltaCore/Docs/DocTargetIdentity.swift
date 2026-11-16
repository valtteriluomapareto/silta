/// The immutable map identity named by a proposal attachment.
struct DocTargetIdentity: Codable, Hashable, Sendable {
  let kind: String
  let uid: String
}
