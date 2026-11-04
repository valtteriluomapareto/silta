/// Mutations available for existing task discussion.
package enum CommentAction: String, Sendable {
  case resolve, reopen, delete

  var receipt: String {
    switch self {
    case .resolve: "resolved"
    case .reopen: "reopened"
    case .delete: "deleted"
    }
  }
}
