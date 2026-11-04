import SiltaCore

enum CommentOutput {
  private static let fields: [String: Shape] = [
    "ref": .string, "kind": .string, "body": .string, "actor": .string,
    "reply_to": .optional(.string), "deleted": .bool, "resolved_at": .optional(.string),
    "created_at": .string,
  ]
  static let shape = Shape.object(fields)
  static let receiptShape = Shape.object(fields.merging(["released": .bool]) { _, new in new })

  static func detail(_ post: CommentDetails, comments: [CommentDetails], timeline: Bool)
    -> String
  {
    var text = "\(post.ref) \(post.kind) by \(post.actor)"
    if timeline { text = post.createdAt + " " + text }
    if let reply = post.replyTo { text += " (reply to \(reply))" }
    if post.kind == "question" {
      let answered = comments.contains {
        $0.replyTo == post.ref && $0.kind == "answer" && !$0.deleted
      }
      text +=
        " [" + (answered ? "answered, " : "") + (post.resolvedAt == nil ? "unresolved" : "resolved")
        + "]"
    }
    text +=
      "\n"
      + post.body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    return text
  }
}
