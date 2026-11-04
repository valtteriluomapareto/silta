/// Mutations available for existing task discussion.
package enum CommentAction: String, Sendable {
  case resolve, reopen, delete

  /// A body-free invocation shared by CLI recovery and transaction audits.
  package func command(_ refs: [String], workspace: String? = nil) -> String {
    let scope = workspace.map { "--ws " + shellWord($0) + " " } ?? ""
    return "silta " + scope + "comment " + rawValue + " "
      + refs.map { shellWord(SecretGuard.redacted($0)) }.joined(separator: " ")
  }

  var receipt: String {
    switch self {
    case .resolve: "resolved"
    case .reopen: "reopened"
    case .delete: "deleted"
    }
  }
}
