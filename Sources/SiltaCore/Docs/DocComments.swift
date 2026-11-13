enum DocComments {
  static func render(_ post: CommentDetails) -> String {
    let flags =
      [post.kind] + (post.accepted ? ["accepted"] : []) + (post.deleted ? ["deleted"] : [])
    var output =
      "\(post.ref) [\(flags.joined(separator: ", "))]\n"
      + "actor: \(post.actor)\ncreated_at: \(post.createdAt)\n"
    if let root = post.replyTo { output += "reply_to: \(root)\n" }
    if let resolved = post.resolvedAt { output += "resolved_at: \(resolved)\n" }
    if let actor = post.resolvedBy { output += "resolved_by: \(actor)\n" }
    if !post.mentions.isEmpty { output += "mentions: \(post.mentions.joined(separator: ", "))\n" }
    if let source = post.source { output += "from: \(source)\n" }
    return SecretGuard.redacted(output + "\n" + post.body) + "\n"
  }
}
