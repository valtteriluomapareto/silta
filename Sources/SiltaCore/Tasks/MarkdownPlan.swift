import Foundation

/// The small Markdown subset used for importing and ticking task checklists.
package struct MarkdownPlan: Sendable {
  /// A top-level checkbox outside fences: what `--step N` counts, from 1.
  struct Checkbox: Sendable {
    let line: Int

    let done: Bool

    let title: String
  }

  struct Step: Sendable {
    var title: String

    var description: String
  }

  var title: String

  var description: String

  var steps: [Step]

  var checklist: String

  init(_ text: String) throws {
    let lines = text.components(separatedBy: "\n")
    let visible = Self.visibleLines(lines)
    let heading = visible.first { lines[$0].firstMatch(of: /^#{1,6} +(.+?)\r?$/) != nil }
    guard let heading,
      let titleMatch = lines[heading].firstMatch(of: /^#{1,6} +(.+?)\r?$/)
    else { throw TaskError.invalid("A plan needs a Markdown heading for its title.") }
    title = String(titleMatch.output.1)
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("A plan title must be nonblank.")
    }
    let lists = visible.filter { Self.item(lines[$0]) != nil }
    let starts =
      lists.isEmpty
      ? visible.filter { $0 != heading && lines[$0].hasPrefix("## ") } : lists
    guard !starts.isEmpty else {
      throw TaskError.invalid("A plan needs top-level list items or ## headings for its steps.")
    }
    let first = starts[0]
    description =
      lines[..<first].enumerated().filter { $0.offset != heading }
      .map(\.element).joined(separator: "\n") + "\n"
    while description.hasPrefix("\n") { description.removeFirst() }
    var output = lines
    steps = starts.enumerated().map { index, line in
      let end = index + 1 < starts.count ? starts[index + 1] : lines.count
      let raw =
        Self.item(lines[line])
        ?? String(lines[line].dropFirst(3)).replacingOccurrences(
          of: "\r", with: "")
      let label = raw.replacing(/^\[[ xX]\] +/, with: "")
      let mark = raw.hasPrefix("[x]") || raw.hasPrefix("[X]") ? "x" : " "
      output[line] = "- [\(mark)] \(label)" + (lines[line].hasSuffix("\r") ? "\r" : "")
      return Step(
        title: label,
        description: lines[(line + 1)..<end].joined(separator: "\n")
          + (end < lines.count ? "\n" : ""))
    }
    guard steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw TaskError.invalid("Plan step titles must be nonblank.")
    }
    checklist = output.joined(separator: "\n")
  }

  static func checkboxes(_ text: String) -> [Checkbox] {
    let lines = text.components(separatedBy: "\n")
    return visibleLines(lines).compactMap { index in
      // Only the prefix is matched: `.` stops at U+2028 and \v, which a label may hold.
      lines[index].prefixMatch(of: #/(?:[-+*]|[0-9]+[.)]) +\[([ xX])\] /#).map {
        let rest = lines[index][$0.range.upperBound...]
        return Checkbox(
          line: index, done: $0.output.1 != " ",
          title: String(rest.hasSuffix("\r") ? rest.dropLast() : rest))
      }
    }
  }

  /// `text` with each checkbox's list marker replaced by its step number, as `task show`
  /// prints it.
  package static func numbered(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    for (number, box) in checkboxes(text).enumerated() {
      lines[box.line] = lines[box.line].replacing(
        #/^(?:[-+*]|[0-9]+[.)]) +/#, with: "\(number + 1). ", maxReplacements: 1)
    }
    return lines.joined(separator: "\n")
  }

  static func tick(_ text: String, step: Int, done: Bool) throws -> String {
    var lines = text.components(separatedBy: "\n")
    let boxes = checkboxes(text)
    guard step > 0, step <= boxes.count else {
      throw TaskError.invalid("--step must name an existing top-level checkbox (numbered from 1).")
    }
    let index = boxes[step - 1].line
    guard let opening = lines[index].firstIndex(of: "[") else { throw StorageError.unavailable }
    let mark = lines[index].index(after: opening)
    lines[index].replaceSubrange(mark...mark, with: done ? "x" : " ")
    return lines.joined(separator: "\n")
  }

  private static func item(_ line: String) -> String? {
    line.firstMatch(of: /^(?:[-+*]|[0-9]+[.)]) +(.+?)\r?$/).map { String($0.output.1) }
  }

  static func visibleLines(_ lines: [String]) -> [Int] { visibility(lines).lines }

  static func visibility(_ lines: [String]) -> (lines: [Int], unclosedFence: Bool) {
    var fence: (Character, Int)?
    var visible: [Int] = []
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let indentation = line.prefix(while: { $0 == " " })
      if indentation.count < 4,
        let first = line.dropFirst(indentation.count).first, first == "`" || first == "~"
      {
        let count = trimmed.prefix { $0 == first }.count
        if count >= 3 {
          if let current = fence {
            if first == current.0, count >= current.1,
              trimmed.dropFirst(count).isEmpty
            {
              fence = nil
            }
          } else {
            fence = (first, count)
          }
          continue
        }
      }
      if fence == nil { visible.append(index) }
    }
    return (visible, fence != nil)
  }
}
