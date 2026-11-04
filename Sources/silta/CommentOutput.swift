import SiltaCore

enum CommentOutput {
  private static let fields: [String: Shape] = [
    "ref": .string, "kind": .string, "body": .string, "actor": .string,
    "reply_to": .optional(.string), "deleted": .bool, "resolved_at": .optional(.string),
    "created_at": .string, "resolved_by": .optional(.string),
    "mentions": .array(.string), "accepted": .bool, "from": .optional(.string),
  ]
  static let shape = Shape.object(fields)
  static let receiptShape = Shape.object(fields.merging(["released": .bool]) { _, new in new })

  static let mutationShape = Shape.object([
    "action": .string, "refs": .array(.string), "created": .array(.string),
  ])

  static func mutation(_ result: CommentMutationResult) -> CommandOutput {
    let unchanged = Set(result.unchanged)
    let already = result.action == "reopened" ? "open" : result.action
    var lines = result.refs.map {
      $0 + " " + (unchanged.contains($0) ? "already " + already : result.action)
    }
    if !result.created.isEmpty {
      lines.append("explanations: " + result.created.joined(separator: " "))
    }
    return CommandOutput(
      text: lines.joined(separator: "\n"),
      quiet: result.created.joined(separator: "\n"), data: result,
      warnings: result.warnings, approvalUsed: result.approvalUsed)
  }

  static func detail(
    _ post: CommentDetails, comments: [CommentDetails], timeline: Bool
  )
    -> String
  {
    var text = "\(post.ref) \(post.kind) by \(post.actor)"
    if timeline { text = post.createdAt + " " + text }
    if let reply = post.replyTo { text += " (reply to \(reply))" }
    let resolution = post.resolvedBy.map { "resolved by " + $0 } ?? "resolved"
    if post.kind == "question" {
      let answered = comments.contains {
        $0.replyTo == post.ref && $0.kind == "answer" && !$0.deleted
      }
      text +=
        " [" + (answered ? "answered, " : "") + (post.resolvedAt == nil ? "unresolved" : resolution)
        + "]"
    }
    if post.kind != "question", post.resolvedAt != nil { text += " [" + resolution + "]" }
    if !post.mentions.isEmpty { text += " (to " + post.mentions.joined(separator: ", ") + ")" }
    if post.accepted { text += " [accepted]" }
    if let source = post.source { text += " (from " + source + ")" }
    var body = post.body
    if body.last?.isNewline == true { body.removeLast() }
    text +=
      "\n"
      + body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    return text
  }
}
