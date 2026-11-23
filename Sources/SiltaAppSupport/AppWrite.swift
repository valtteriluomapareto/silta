/// One action the human takes in the app; each is one SiltaCore write.
public enum AppWrite: Equatable, Sendable {
  /// Answers a question on a task, in the question's thread.
  case answer(task: String, question: String, body: String)
  /// Posts a comment on a task, as a new thread or as a reply in `replyTo`'s thread. `kind`
  /// is `comment`, `decision` or `question` to the actors in `to`.
  case comment(
    task: String, body: String, replyTo: String? = nil, kind: String = "comment",
    to: [String] = [])
  /// Creates a todo task as the human; the app never starts or claims it.
  case createTask(AppNewTask)
  /// Resolves discussion threads by their root or any post in them.
  case resolveThreads(refs: [String])
  /// Reopens resolved discussion threads.
  case reopenThreads(refs: [String])
  /// Accepts an answer to the human's question, resolving its thread.
  case acceptAnswer(ref: String)
  /// Accepts task proposals as todo work, all or none.
  case acceptProposals(refs: [String])
  /// Drops task proposals, all or none, with an optional reason recorded as their result.
  case dropProposals(refs: [String], why: String?)
  /// Returns a ready blocked task to todo; one that isn't ready refuses as `blocked`.
  case unblock(ref: String)

  /// The §19 command name, distinct from every CLI command.
  var logCommand: String {
    switch self {
    case .answer: "app answer"
    case .comment: "app comment"
    case .acceptAnswer: "app accept-answer"
    case .acceptProposals, .dropProposals: "app triage"
    case .unblock: "app unblock"
    case .createTask: "app add"
    case .resolveThreads: "app resolve"
    case .reopenThreads: "app reopen"
    }
  }
}
