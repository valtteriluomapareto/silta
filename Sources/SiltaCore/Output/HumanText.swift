import Foundation

/// Terminal text for stored content. Mask the whole field before changing its layout.
package enum HumanText {
  /// Keeps tabs, normalizes body line breaks to LF and replaces other controls with spaces.
  package static func body(_ text: String) -> String {
    render(text, multiline: true)
  }

  /// Keeps an inline field on one line and replaces controls with spaces.
  package static func line(_ text: String) -> String {
    render(text, multiline: false)
  }

  private static let lineBreaks = CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}")

  private static let controls = CharacterSet.controlCharacters.union(.newlines)
    .subtracting(CharacterSet(charactersIn: "\u{200c}\u{200d}"))

  private static func render(_ text: String, multiline: Bool) -> String {
    let masked = SecretGuard.redacted(text)
    let source = multiline ? masked.replacingOccurrences(of: "\r\n", with: "\n") : masked
    var result = String.UnicodeScalarView()
    for scalar in source.unicodeScalars {
      if multiline && lineBreaks.contains(scalar) {
        result.append("\n")
      } else {
        let layout = multiline && scalar == "\t"
        result.append(!layout && controls.contains(scalar) ? " " : scalar)
      }
    }
    return String(result)
  }
}
