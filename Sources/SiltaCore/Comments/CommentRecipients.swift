import Foundation

/// Resolves explicit recipients and reserved mention tokens outside Markdown code spans and fences.
enum CommentRecipients {
  static func resolve(_ input: [String], body: String, human: ActorID, question: Bool) throws
    -> [String]
  {
    let pattern =
      #"(?<![A-Za-z0-9_])@(?:me(?=$|[^A-Za-z0-9_])|human:|agent:)[^\s`*<>()\[\]{},;!?"']*"#
    let expression = try NSRegularExpression(pattern: pattern)
    let visible = try prose(body)
    let mentions = expression.matches(
      in: visible, range: NSRange(visible.startIndex..., in: visible)
    )
    .compactMap { Range($0.range, in: visible) }
    .map {
      String(visible[$0].dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
    }
    let tokens = input + mentions
    let actors = try tokens.map { token -> String in
      if token == "me" { return human.description }
      guard let actor = ActorID.parse(token), SecretGuard.matches(in: token).isEmpty else {
        throw CommentError.invalid(
          "Invalid recipient \(String(reflecting: SecretGuard.redacted(token))); use complete "
            + "human:<name> or agent:<tool>:<session> actors, or me. Tool-only actors are refused.")
      }
      return actor.description
    }
    return Set(actors.isEmpty && question ? [human.description] : actors).sorted()
  }

  private static func prose(_ body: String) throws -> String {
    var fence: (Character, Int)?
    let parts = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    let lines = parts.map { line in
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
      if let (marker, length) = fence {
        let run = trimmed.prefix(while: { $0 == marker })
        if run.count >= length, trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace) {
          fence = nil
        }
        return ""
      }
      if let marker = trimmed.first, marker == "`" || marker == "~" {
        let length = trimmed.prefix(while: { $0 == marker }).count
        if length >= 3 {
          fence = (marker, length)
          return ""
        }
      }
      return String(line)
    }.joined(separator: "\n")
    let code = try NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)"#)
    return code.stringByReplacingMatches(
      in: lines, range: NSRange(lines.startIndex..., in: lines), withTemplate: " ")
  }
}
