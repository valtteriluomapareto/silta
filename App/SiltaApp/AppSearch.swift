import Foundation

nonisolated enum AppSearch {
  static func matches(_ query: String, values: [String]) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let referenceQuery =
      query.range(
        of: "^(?:[A-Za-z][A-Za-z0-9]*-[0-9]+(?:/[0-9]+)?|doc:[^[:space:]@]+@[0-9]+)$",
        options: [.regularExpression, .caseInsensitive]) != nil
    return values.contains { value in
      if !referenceQuery { return value.localizedCaseInsensitiveContains(query) }
      return value.split { !$0.isLetter && !$0.isNumber && !"-_/@:.".contains($0) }
        .contains {
          String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .caseInsensitiveCompare(query) == .orderedSame
        }
    }
  }
}
