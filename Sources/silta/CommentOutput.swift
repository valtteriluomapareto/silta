import SiltaCore

enum CommentOutput {
  private static let fields: [String: Shape] = [
    "ref": .string, "kind": .string, "body": .string, "actor": .string,
    "reply_to": .optional(.string), "deleted": .bool, "resolved_at": .optional(.string),
    "created_at": .string,
  ]
  static let shape = Shape.object(fields)
  static let receiptShape = Shape.object(fields.merging(["released": .bool]) { _, new in new })

  static let mutationShape = Shape.object([
    "action": .string, "refs": .array(.string), "created": .array(.string),
  ])

  static func mutation(_ result: CommentMutationResult) -> CommandOutput {
    CommandOutput(
      text: result.refs.map { $0 + " " + result.action }.joined(separator: "\n"),
      quiet: result.created.joined(separator: "\n"), data: result,
      warnings: result.warnings, approvalUsed: result.approvalUsed)
  }

  static func detail(
    _ post: CommentDetails, comments: [CommentDetails], timeline: Bool, workspace: String?
  )
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
    if post.kind != "question", post.resolvedAt != nil { text += " [resolved]" }
    var body = post.body
    if body.last?.isNewline == true { body.removeLast() }
    text +=
      "\n"
      + body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    if let workspace, post.replyTo == nil {
      text +=
        "\nnext: silta --ws " + shellWord(workspace) + " comment "
        + (post.resolvedAt == nil ? "resolve " : "reopen ") + shellWord(post.ref)
    }
    return text
  }
}
