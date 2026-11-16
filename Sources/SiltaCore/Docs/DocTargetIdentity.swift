/// The immutable map identity named by a proposal attachment.
struct DocTargetIdentity: Codable, Hashable, Sendable {
  let kind: String
  let uid: String
  static func encoded(_ targets: [Self]) throws -> String {
    try WorkspaceConfig.json(targets.map { ["kind": $0.kind, "uid": $0.uid] })
  }

}
