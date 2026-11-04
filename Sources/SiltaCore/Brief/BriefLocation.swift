/// Compact location metadata; optional candidate details live in budgeted sections.
package struct BriefLocation: Encodable, Sendable {
  /// Workspace resolved from the registered repository.
  package let workspace: String
  let repo: String
  let app: String?
  let branch: String?
  let confidence: String
  let reason: String

  init(_ location: LocationResult) {
    workspace = location.workspace
    repo = location.repo
    app = location.app
    branch = location.branch
    confidence = location.confidence
    reason = location.reason
  }

  enum CodingKeys: String, CodingKey { case workspace, repo, app, branch, confidence, reason }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(workspace, forKey: .workspace)
    try values.encode(repo, forKey: .repo)
    try values.encode(app, forKey: .app)
    try values.encode(branch, forKey: .branch)
    try values.encode(confidence, forKey: .confidence)
    try values.encode(reason, forKey: .reason)
  }

  var text: String {
    "\(workspace) / \(repo) / \(app ?? "unresolved") [\(confidence): \(reason)]\n"
      + "branch: \(TaskError.shown(branch ?? "(detached)"))\n"
  }
}
