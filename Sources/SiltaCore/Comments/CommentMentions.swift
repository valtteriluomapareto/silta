import Foundation

enum CommentMentions {
  static func parse(_ body: String, to: [String], human: ActorID, question: Bool) throws -> [String]
  {
    let regex = try NSRegularExpression(
      pattern: #"(?<![A-Za-z0-9_@])@(me\b|(?:human|agent|ext):[^\s,;!?()\[\]<>"']+)"#)
    let tokens = try regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
      guard let range = Range($0.range(at: 1), in: body) else { throw StorageError.unavailable }
      return String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    let actors = try (tokens + to).map { raw -> String in
      let word = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
      if word == "me" { return human.description }
      guard let actor = ActorID.parse(word) else {
        throw CommentError.invalid(
          "Mentions and --to need me, human:<name> or agent:<tool>:<session>; "
            + "external parties belong to task block."
        )
      }
      return actor.description
    }
    return Array(Set(actors.isEmpty && question ? [human.description] : actors)).sorted()
  }
}
