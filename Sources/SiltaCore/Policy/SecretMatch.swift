/// A detected secret span. Ranges belong to the exact string passed to the scanner.
package struct SecretMatch: Sendable {
  /// Stable id of the first rule in an overlapping group.
  package let rule: String
  /// Entire covered range, including any overlapping detected secrets.
  package let range: Range<String.Index>

  /// Reveals at most four leading characters, always hiding at least one character.
  /// Only use the original scanned string; control characters are removed from previews.
  package func preview(in text: String) -> String {
    let value = text[range]
    let visible = value.prefix(min(4, max(0, value.count - 1)))
      .filter {
        !$0.isNewline && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      }
    return visible + "…[\(rule)]"
  }
}
