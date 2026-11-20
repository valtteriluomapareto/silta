import Foundation

/// Terminal text for stored content. Mask the whole field before changing its layout.
package enum HumanText {
  /// Keeps tabs, normalizes body line breaks to LF and replaces other controls with spaces.
  package static func body(_ text: String) -> String {
    render(text, layout: .body)
  }

  /// Keeps existing LF coordinates and tabs while neutralizing other control characters.
  package static func framed(_ text: String) -> String {
    render(text, layout: .framed)
  }

  /// Keeps an inline field on one line and replaces controls with spaces.
  package static func line(_ text: String) -> String {
    render(text, layout: .line)
  }

  private enum Layout {
    case line, body, framed
  }

  private static let lineBreaks = CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}")

  private static let controls = CharacterSet.controlCharacters.union(.newlines)
    .subtracting(CharacterSet(charactersIn: "\u{200c}\u{200d}"))

  private static func render(_ text: String, layout: Layout) -> String {
    let masked =
      layout == .framed
      ? SecretGuard.redacted(
        text, matches: SecretGuard.matches(in: text), preservingLineFeeds: true)
      : SecretGuard.redacted(text)
    let multiline = layout != .line
    let source = multiline ? masked.replacingOccurrences(of: "\r\n", with: "\n") : masked
    var result = String.UnicodeScalarView()
    for scalar in source.unicodeScalars {
      if layout == .body && lineBreaks.contains(scalar) {
        result.append("\n")
      } else {
        let kept = multiline && (scalar == "\n" || scalar == "\t")
        result.append(!kept && controls.contains(scalar) ? " " : scalar)
      }
    }
    return String(result)
  }
}
