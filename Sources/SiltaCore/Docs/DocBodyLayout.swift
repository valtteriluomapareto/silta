/// Byte ownership is recorded during composition, before full-view masking or selection.
struct DocBodyLayout: Sendable {
  var output = ""
  var title: Range<Int>?
  var about: [Range<Int>]?
  var aboutField: Range<Int>?
  var state: Range<Int> = 0..<0
  var body: Range<Int> = 0..<0

  mutating func append(_ value: String) {
    output += value
  }

  mutating func field(_ value: String) -> Range<Int> {
    let start = output.utf8.count
    append(value)
    return start..<output.utf8.count
  }

  func project(
    matches: [SecretMatch], masked: String, visible: Range<Int>, into result: inout DocReadResult
  ) {
    let spans = matches.map { match in
      let lower = output.utf8.distance(from: output.utf8.startIndex, to: match.range.lowerBound)
      let upper = output.utf8.distance(from: output.utf8.startIndex, to: match.range.upperBound)
      return (range: lower..<upper, count: match.replacement.utf8.count)
    }
    func position(_ offset: Int) -> Int {
      var shift = 0
      for span in spans {
        if offset <= span.range.lowerBound { break }
        if offset < span.range.upperBound {
          return span.range.lowerBound + shift + span.count
        }
        shift += span.count - span.range.count
      }
      return offset + shift
    }
    func text(_ range: Range<Int>) -> String {
      let lower = masked.utf8.index(masked.utf8.startIndex, offsetBy: range.lowerBound)
      let upper = masked.utf8.index(lower, offsetBy: range.count)
      return String(masked[lower..<upper])
    }
    func complete(_ raw: Range<Int>) -> String? {
      guard
        !spans.contains(where: {
          $0.range.overlaps(raw)
            && ($0.range.lowerBound < raw.lowerBound || $0.range.upperBound > raw.upperBound)
            || raw.isEmpty && $0.range.lowerBound < raw.lowerBound
              && raw.lowerBound < $0.range.upperBound
        })
      else { return nil }
      let range = position(raw.lowerBound)..<position(raw.upperBound)
      guard visible.lowerBound <= range.lowerBound, range.upperBound <= visible.upperBound,
        !visible.isEmpty
      else { return nil }
      return text(range)
    }
    let start = max(visible.lowerBound, position(body.lowerBound))
    let end = min(visible.upperBound, position(body.upperBound))
    result.body = text(start..<max(start, end))
    result.title = title.flatMap(complete)
    if let about, let aboutField, complete(aboutField) != nil {
      let values = about.compactMap(complete)
      if values.count == about.count { result.about = values }
    }
    result.state = complete(state)
  }
}
