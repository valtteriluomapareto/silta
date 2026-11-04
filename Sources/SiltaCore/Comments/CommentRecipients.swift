import Foundation

/// Resolves explicit recipients and reserved mention tokens without parsing Markdown.
enum CommentRecipients {
  static func resolve(_ input: [String], body: String, human: ActorID, question: Bool) throws
    -> [String]
  {
    let pattern =
      #"(?<![A-Za-z0-9_])@(?:me(?=$|[^A-Za-z0-9_])|human:|agent:)[^\s`*<>()\[\]{},;!?"']*"#
    let expression = try NSRegularExpression(pattern: pattern)
    let mentions = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
      .compactMap { Range($0.range, in: body) }
      .map { String(body[$0].dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
    let tokens = input + mentions
    let actors = try tokens.map { token -> String in
      if token == "me" { return human.description }
      guard let actor = ActorID.parse(token), SecretGuard.matches(in: token).isEmpty else {
        throw CommentError.invalid(
          "Recipients must be complete human:<name> or agent:<tool>:<session> actors, or me.")
      }
      return actor.description
    }
    return Set(actors.isEmpty && question ? [human.description] : actors).sorted()
  }
}
