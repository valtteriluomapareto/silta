import Foundation

/// The five fields supported by task editing, with a lossless Markdown file representation.
package struct TaskEditDocument: Equatable, Sendable {
  /// The task title.
  package var title: String

  /// Markdown describing the work.
  package var description: String

  /// Markdown acceptance criteria.
  package var acceptance: String

  /// The current plan, which receives a revision when replaced.
  package var plan: String

  /// The visible result; an unchanged empty value preserves database NULL.
  package var result: String

  private static let headings = ["Title", "Description", "Acceptance", "Plan", "Result"]

  /// Copies the actual editable values from a task read.
  package init(_ task: TaskDetails) {
    title = task.title
    description = task.description
    acceptance = task.acceptance
    plan = task.plan
    result = task.result ?? ""
  }

  var values: [String] {

    [title, description, acceptance, plan, result]

  }

  /// Wraps each value in a tilde fence longer than any value's own tilde run.
  package func render() -> String {
    let longest = values.flatMap { $0.split(whereSeparator: { $0 != "~" }) }.map(\.count).max() ?? 0
    let fence = String(repeating: "~", count: max(3, longest + 1))
    return zip(Self.headings, values).map { heading, value in
      "## \(heading)\n\(fence)\n\(value)\n\(fence)\n"
    }.joined()
  }

  /// Parses ordered fenced sections; headings and fences inside values remain literal text.
  package static func parse(_ text: String, from task: TaskDetails) throws -> Self {
    let separator = text.hasPrefix("## Title\r\n") ? "\r\n" : "\n"
    let lines = text.components(separatedBy: separator)
    var cursor = 0
    var fields: [String] = []
    for heading in headings {
      while cursor < lines.count && lines[cursor].isEmpty { cursor += 1 }
      guard cursor + 1 < lines.count, lines[cursor] == "## " + heading else { throw invalid }
      let fence = lines[cursor + 1]
      guard fence.count >= 3, fence.allSatisfy({ $0 == "~" }) else { throw invalid }
      cursor += 2
      let start = cursor
      while cursor < lines.count && lines[cursor] != fence { cursor += 1 }
      guard cursor < lines.count, cursor > start else { throw invalid }
      fields.append(lines[start..<cursor].joined(separator: separator))
      cursor += 1
    }
    guard lines[cursor...].allSatisfy(\.isEmpty) else { throw invalid }
    var document = Self(task)
    document.title = fields[0]
    document.description = fields[1]
    document.acceptance = fields[2]
    document.plan = fields[3]
    document.result = fields[4]
    guard !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("A task title is required.")
    }
    return document
  }

  private static var invalid: TaskError {
    .invalid("Use five ordered fenced sections: Title, Description, Acceptance, Plan, Result.")
  }
}
