nonisolated enum CommandPresentation {
  struct Part: Equatable {
    let text: String
    let warning: Bool
  }

  static func parts(_ text: String) -> [Part] {
    var result: [Part] = []
    var index = text.startIndex
    while index < text.endIndex {
      let start = index
      let whitespace = text[index].isWhitespace
      var quote: Character?
      while index < text.endIndex {
        let character = text[index]
        if whitespace {
          guard character.isWhitespace else { break }
        } else {
          if quote == nil && character.isWhitespace { break }
          if character == "\\", quote != "'" {
            index = text.index(after: index)
            if index < text.endIndex { index = text.index(after: index) }
            continue
          }
          if character == quote {
            quote = nil
          } else if quote == nil && (character == "'" || character == "\"") {
            quote = character
          }
        }
        index = text.index(after: index)
      }
      let word = String(text[start..<index])
      result.append(Part(text: word, warning: ["REFS", "MERGE_SHA", "\"\""].contains(word)))
    }
    return result
  }
}
