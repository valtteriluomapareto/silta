import SiltaCore

enum CommentOutput {
  static let shape = Shape.object([
    "ref": .string, "kind": .string, "body": .string, "actor": .string,
    "mentions": .array(.string), "reply_to": .optional(.string), "source": .optional(.string),
    "accepted": .bool, "deleted": .bool, "resolved_at": .optional(.string),
    "resolved_by": .optional(.string), "created_at": .string,
  ])

  static func detail(_ post: CommentDetails, comments: [CommentDetails], workspace: String)
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
    if post.accepted { text += " [accepted]" }
    if !post.mentions.isEmpty { text += " -> " + post.mentions.joined(separator: ", ") }
    text += "\n" + post.body
    if let source = post.source { text += "\ncites: " + source }
    if post.kind == "question", !post.deleted, post.resolvedAt == nil {
      let task = String(post.ref.prefix { $0 != "/" })
      text +=
        "\nReply: silta --ws " + shellWord(workspace) + " comment " + shellWord(task)
        + " --kind answer --reply-to " + shellWord(post.ref) + " -F -"
    }
    return text
  }
}
