/// The workspace and any Git evidence behind the brief's location metadata.
package struct BriefLocation: Encodable, Sendable {
  /// The selected workspace.
  package let workspace: String
  let git: LocationResult?
  let taskRef: String?

  var app: String? { git?.app }
  var confidence: String { git?.confidence ?? "low" }

  init(_ location: LocationResult) {
    workspace = location.workspace
    git = location
    taskRef = location.currentTask?.ref
  }

  init(workspace: String, task: String?) {
    self.workspace = workspace
    git = nil
    taskRef = task
  }

  enum CodingKeys: String, CodingKey { case workspace, repo, app, branch, confidence, reason }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(workspace, forKey: .workspace)
    try values.encode(git?.repo ?? "", forKey: .repo)
    try values.encode(app, forKey: .app)
    try values.encode(git?.branch, forKey: .branch)
    try values.encode(confidence, forKey: .confidence)
    try values.encode(git?.reason ?? "workspace_only", forKey: .reason)
  }

  var text: String {
    guard let git else { return "workspace: \(TaskError.shown(workspace)) (outside Git)\n" }
    return "\(workspace) / \(git.repo) / \(app ?? "unresolved") [\(confidence): \(git.reason)]\n"
      + "branch: \(TaskError.shown(git.branch ?? "(detached)"))\n"
  }
}
