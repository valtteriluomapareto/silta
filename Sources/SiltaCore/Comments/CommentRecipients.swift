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
    let parts = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(
      String.init)
    var lines = parts
    var fence: (start: Int, delimiter: String)?
    for index in parts.indices {
      let trimmed = parts[index].drop(while: { $0 == " " || $0 == "\t" })
      if let open = fence {
        let run = trimmed.prefix(while: { open.delimiter.contains($0) })
        if run.count >= open.delimiter.count,
          trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace)
        {
          for hidden in open.start...index { lines[hidden] = "" }
          fence = nil
        }
      } else if let marker = trimmed.first, marker == "`" || marker == "~" {
        let length = trimmed.prefix(while: { $0 == marker }).count
        if length >= 3 { fence = (index, String(trimmed.prefix(length))) }
      }
    }
    if let open = fence {
      // An unterminated opener is prose, not an inline-code delimiter.
      lines[open.start] = String(
        parts[open.start].drop(while: { $0 == " " || $0 == "\t" }).dropFirst(open.delimiter.count))
    }
    let visible = lines.joined(separator: "\n")
    let code = try NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)"#)
    return code.stringByReplacingMatches(
      in: visible, range: NSRange(visible.startIndex..., in: visible), withTemplate: " ")
  }
}
