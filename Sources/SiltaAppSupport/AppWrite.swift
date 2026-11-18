/// One action the human takes in the app; each is one SiltaCore write.
public enum AppWrite: Equatable, Sendable {
  /// Answers a question on a task, in the question's thread.
  case answer(task: String, question: String, body: String)
  /// Posts a plain comment on a task.
  case comment(task: String, body: String)
  /// Accepts an answer to the human's question, resolving its thread.
  case acceptAnswer(String)

  /// The §19 command name, distinct from every CLI command.
  var logCommand: String {
    switch self {
    case .answer: "app answer"
    case .comment: "app comment"
    case .acceptAnswer: "app accept-answer"
    }
  }
}
