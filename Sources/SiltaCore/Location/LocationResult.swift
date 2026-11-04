/// A location report; an unresolved app is absent, and detached HEAD has a null branch.
package struct LocationResult: Encodable, Sendable {
  /// Canonical inspected directory, preserved in path-sensitive retries.
  package let path: String
  /// Canonical worktree toplevel, used only for override identity and receipts.
  package let worktree: String
  /// Whether an override request changed stored state; absent for ordinary reads.
  package var overrideChanged: Bool?
  /// The workspace containing the registered repository.
  package let workspace: String
  /// The registered repository slug.
  package let repo: String
  /// The selected app, present only at high confidence.
  package var app: String?
  /// The current branch, or nil for detached HEAD.
  package let branch: String?
  /// The complete HEAD commit identity.
  package let head: String
  /// Either high or low; callers requiring an app must check this.
  package var confidence: String
  /// The rule that produced this report.
  package var reason: String
  /// The filtered candidates, sorted by app slug.
  package let candidates: [LocationCandidate]
  /// Missing-ref diagnostics, rendered in the envelope rather than data.
  package var warnings: [OutputWarning] = []

  private enum CodingKeys: String, CodingKey {
    case workspace, repo, app, branch, head, confidence, reason, candidates
  }

  /// Preserves the required null branch for detached HEAD; an unresolved app stays absent.
  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(workspace, forKey: .workspace)
    try values.encode(repo, forKey: .repo)
    try values.encodeIfPresent(app, forKey: .app)
    try values.encode(branch, forKey: .branch)
    try values.encode(head, forKey: .head)
    try values.encode(confidence, forKey: .confidence)
    try values.encode(reason, forKey: .reason)
    try values.encode(candidates, forKey: .candidates)
  }
}

/// An app that can own code at the input path.
package struct LocationCandidate: Encodable, Equatable, Sendable {
  let id: Int64
  /// The app slug for explicit selection.
  package let app: String
  /// The configured development ref.
  package let ref: String
  let prodRef: String?
  let subpath: String?

  private enum CodingKeys: String, CodingKey {
    case app, ref
  }
}
