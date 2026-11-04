import SiltaCore

enum CommentOutput {
  static let shape = Shape.object([
    "ref": .string, "kind": .string, "body": .string, "actor": .string,
    "reply_to": .optional(.string), "deleted": .bool, "resolved_at": .optional(.string),
    "created_at": .string,
  ])

  static func detail(_ post: CommentDetails, comments: [CommentDetails])
    -> String
  {
    var text = "\(post.ref) \(post.kind) by \(post.actor)"
    if let reply = post.replyTo { text += " (reply to \(reply))" }
    if post.kind == "question" {
      let answered = comments.contains {
        $0.replyTo == post.ref && $0.kind == "answer" && !$0.deleted
      }
      text +=
        " [" + (answered ? "answered, " : "") + (post.resolvedAt == nil ? "unresolved" : "resolved")
        + "]"
    }
    text += "\n" + post.body
    return text
  }
}
