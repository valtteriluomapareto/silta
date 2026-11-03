/// A detected secret span. Ranges belong to the exact string passed to the scanner.
package struct SecretMatch: Sendable {
  /// Stable id of the first rule in an overlapping group.
  package let rule: String
  /// Entire covered range, including any overlapping detected secrets.
  package let range: Range<String.Index>

  /// Reveals at most four leading characters, always hiding at least one character.
  /// Those are a public marker (`AKIA`, `ghp_`, a field name) for every rule except a
  /// henkilötunnus (a birth date) and an Azure PAT (the token itself), which show none.
  /// Only use the original scanned string; control characters are removed from previews.
  package func preview(in text: String) -> String {
    let value = text[range]
    let shown = ["hetu", "azure_pat"].contains(rule) ? 0 : 4
    let visible = value.prefix(min(shown, max(0, value.count - 1)))
      .filter {
        !$0.isNewline && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      }
    return visible + "…[\(rule)]"
  }
}
