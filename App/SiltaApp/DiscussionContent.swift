import Foundation
import SiltaAppSupport

/// A task's discussion as threads: each root with its replies, open threads in Core's
/// order and resolved ones after them.
nonisolated struct DiscussionContent {
  struct Thread: Identifiable, Equatable {
    let root: AppComment
    let replies: [AppComment]
    var id: String { root.ref }
    var resolved: Bool { root.resolvedAt != nil }

    /// Replies shown while the thread is folded: all of up to two, else only the newest.
    func visibleReplies(expanded: Bool) -> [AppComment] {
      expanded || replies.count <= DiscussionContent.unfoldedReplies
        ? replies : Array(replies.suffix(1))
    }

    /// How many earlier replies the fold hides.
    func foldedCount(expanded: Bool) -> Int {
      replies.count - visibleReplies(expanded: expanded).count
    }

    /// The thread's state line, such as "Open · 2 replies".
    var state: String {
      let count = replies.isEmpty ? nil : DiscussionContent.replyCount(replies.count)
      return ([resolved ? "Resolved" : "Open"] + [count].compactMap { $0 })
        .joined(separator: " · ")
    }
  }

  /// A thread with more replies than this folds the earlier ones.
  static let unfoldedReplies = 2

  let open: [Thread]
  let resolved: [Thread]
  var isEmpty: Bool { open.isEmpty && resolved.isEmpty }
  var count: Int { open.count + resolved.count }

  init(comments: [AppComment], resolved: [AppComment]) {
    open = Self.threads(comments)
    self.resolved = Self.threads(resolved)
  }

  /// Groups posts in order: a root starts a thread and its replies join it. A reply whose
  /// root isn't in the list starts its own thread rather than disappearing.
  static func threads(_ posts: [AppComment]) -> [Thread] {
    let refs = Set(posts.map(\.ref))
    let roots = posts.filter { $0.replyTo == nil || !refs.contains($0.replyTo ?? "") }
    return roots.map { root in
      Thread(root: root, replies: posts.filter { $0.replyTo == root.ref && $0.ref != root.ref })
    }
  }

  static func replyCount(_ count: Int) -> String {
    count == 1 ? "1 reply" : "\(count) replies"
  }

  /// "Claude", or "You" for the human the app acts as.
  static func name(_ actor: String, human: String) -> String {
    actor == human ? "You" : ActorPresentation(actor).name
  }

  /// The post's kind as a header word: replies say "reply" unless they are answers, and a
  /// question names whom it asks.
  static func kind(_ comment: AppComment, isReply: Bool, human: String) -> String {
    if comment.kind == "question", !comment.mentions.isEmpty {
      return "question to "
        + comment.mentions.map { name($0, human: human) == "You" ? "you" : name($0, human: human) }
        .joined(separator: ", ")
    }
    return isReply && comment.kind == "comment" ? "reply" : comment.kind
  }

  /// The one-line summary of a folded resolved thread: its root's first words.
  static func summary(_ thread: Thread, human: String) -> String {
    let text = thread.root.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return name(thread.root.actor, human: human) + ": " + text
  }
}
