import Foundation

nonisolated enum AppSearch {
  static func matches(_ query: String, values: [String]) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let taskRef =
      query.range(of: "^[A-Za-z][A-Za-z0-9]*-[0-9]+(?:/[0-9]+)?$", options: .regularExpression)
      != nil
    return values.contains { value in
      if !taskRef { return value.localizedCaseInsensitiveContains(query) }
      return value.split { !$0.isLetter && !$0.isNumber && !"-_/@:".contains($0) }
        .contains { String($0).caseInsensitiveCompare(query) == .orderedSame }
    }
  }
}
