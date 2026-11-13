/// Commit evidence prepared before a document write.
struct DocVerification: Sendable {
  struct Snapshot: Codable, Equatable, Sendable {
    let app: String
    let ref: String
    let sha: String
  }

  let snapshots: [Snapshot]

  static func prepare(_ draft: DocDraft, workspace: Int64, environment: SiltaEnvironment)
    async throws -> Self
  {
    throw DocError.invalid("Document verification is unavailable.")
  }
}
