import Foundation

enum DocDiff {
  private static let maximumDepth = 1024
  private static let maximumWork = 1_000_000

  private struct Step {
    let prefix: String
    let line: String
  }

  static func render(_ revision: DocRevision, base: DocRevision?) -> String {
    let ref = "doc:\(revision.slug)@\(revision.revision)"
    let oldRef = base.map { "doc:\($0.slug)@\($0.revision)" } ?? "(empty)"
    let header =
      "\(ref) [\(revision.state)] diff against \(oldRef)\n"
      + "actor: \(revision.actor)\ncreated_at: \(revision.createdAt)\n"
    let newMetadata = metadata(revision)
    let oldMetadata = base.map(metadata) ?? Array(repeating: "", count: newMetadata.count)
    let identitiesChanged: Bool
    if let old = base?.aboutTargets, let new = revision.aboutTargets {
      identitiesChanged = Set(old) != Set(new)
    } else {
      identitiesChanged = false
    }
    let body = steps(old: lines(base?.body ?? ""), new: lines(revision.body))
    let changedBody = body.contains { $0.prefix != " " }
    let changed = zip(oldMetadata, newMetadata).filter { $0 != $1 }
    guard changedBody || identitiesChanged || !changed.isEmpty
    else { return header + "no visible changes\n" }
    let summary =
      header
      + (changed.isEmpty
        ? "metadata unchanged\n"
        : "--- metadata \(oldRef)\n" + (base == nil ? "  (empty)\n" : changed.map(\.0).joined())
          + "+++ metadata \(ref)\n" + changed.map(\.1).joined())
      + (identitiesChanged ? "attachment identities: changed\n" : "")
    guard changedBody else { return summary }
    return summary + "--- \(oldRef)\n+++ \(ref)\n" + hunks(body)
  }

  private static func metadata(_ revision: DocRevision) -> [String] {
    let fields =
      [
        "title: \(revision.title ?? "(unknown)")",
        "kind: \(revision.kind ?? "(unknown)")",
        "about: \(DocService.about(revision.about))",
      ]
      + DocService.evidence(revision).split(
        separator: "\n", maxSplits: 3, omittingEmptySubsequences: false
      ).map(String.init)
    return fields.map {
      SecretGuard.redacted($0).trimmingCharacters(in: .newlines)
        .components(separatedBy: "\n").map { "  " + $0 + "\n" }.joined()
    }
  }

  private static func lines(_ body: String) -> [String] {
    let masked = SecretGuard.redacted(body)
    return masked.isEmpty ? [] : masked.components(separatedBy: "\n")
  }

  private static func steps(old: [String], new: [String]) -> [Step] {
    var prefix = 0
    while prefix < min(old.count, new.count),
      old[prefix].utf8.elementsEqual(new[prefix].utf8)
    { prefix += 1 }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix,
      old[old.count - suffix - 1].utf8.elementsEqual(new[new.count - suffix - 1].utf8)
    { suffix += 1 }
    let left = Array(old[prefix..<(old.count - suffix)])
    let right = Array(new[prefix..<(new.count - suffix)])
    let middle: [Step]
    if !left.isEmpty, !right.isEmpty, let path = trace(old: left, new: right) {
      middle = backtrack(path, old: left, new: right)
    } else {
      middle =
        left.map { Step(prefix: "-", line: $0) }
        + right.map { Step(prefix: "+", line: $0) }
    }
    return old.prefix(prefix).map { Step(prefix: " ", line: $0) }
      + middle + old.suffix(suffix).map { Step(prefix: " ", line: $0) }
  }

  private static func trace(old: [String], new: [String]) -> [[Int]]? {
    guard abs(old.count - new.count) <= maximumDepth else { return nil }
    let offset = maximumDepth + 1
    var frontier = Array(repeating: 0, count: 2 * maximumDepth + 3)
    var path: [[Int]] = []
    var work = 0
    for depth in 0...min(old.count + new.count, maximumDepth) {
      path.append(frontier)
      for diagonal in stride(from: -depth, through: depth, by: 2) {
        work += 1
        guard work <= maximumWork else { return nil }
        var left: Int
        if diagonal == -depth
          || (diagonal != depth
            && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1])
        {
          left = frontier[offset + diagonal + 1]
        } else {
          left = frontier[offset + diagonal - 1] + 1
        }
        var right = left - diagonal
        while left < old.count, right < new.count {
          work += 1
          guard work <= maximumWork else { return nil }
          guard old[left].utf8.elementsEqual(new[right].utf8) else { break }
          left += 1
          right += 1
        }
        frontier[offset + diagonal] = left
        if left >= old.count, right >= new.count { return path }
      }
    }
    return nil
  }

  private static func backtrack(_ path: [[Int]], old: [String], new: [String]) -> [Step] {
    let offset = maximumDepth + 1
    var left = old.count
    var right = new.count
    var result: [Step] = []
    for depth in stride(from: path.count - 1, through: 1, by: -1) {
      let frontier = path[depth]
      let diagonal = left - right
      let previous: Int
      if diagonal == -depth
        || (diagonal != depth && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1])
      {
        previous = diagonal + 1
      } else {
        previous = diagonal - 1
      }
      let previousLeft = frontier[offset + previous]
      let previousRight = previousLeft - previous
      while left > previousLeft, right > previousRight {
        result.append(Step(prefix: " ", line: old[left - 1]))
        left -= 1
        right -= 1
      }
      if left == previousLeft {
        result.append(Step(prefix: "+", line: new[right - 1]))
        right -= 1
      } else {
        result.append(Step(prefix: "-", line: old[left - 1]))
        left -= 1
      }
    }
    while left > 0, right > 0 {
      result.append(Step(prefix: " ", line: old[left - 1]))
      left -= 1
      right -= 1
    }
    return Array(result.reversed())
  }

  private static func hunks(_ steps: [Step]) -> String {
    var windows: [Range<Int>] = []
    for index in steps.indices where steps[index].prefix != " " {
      let window = max(0, index - 3)..<min(steps.count, index + 4)
      if let previous = windows.last, window.lowerBound <= previous.upperBound {
        windows[windows.count - 1] =
          previous.lowerBound..<max(previous.upperBound, window.upperBound)
      } else {
        windows.append(window)
      }
    }
    var output = ""
    var position = 0
    var old = 0
    var new = 0
    for window in windows {
      let skipped = counts(steps[position..<window.lowerBound])
      old += skipped.old
      new += skipped.new
      let size = counts(steps[window])
      output +=
        "@@ -\(size.old == 0 ? old : old + 1),\(size.old)"
        + " +\(size.new == 0 ? new : new + 1),\(size.new) @@\n"
        + steps[window].map { $0.prefix + $0.line + "\n" }.joined()
      old += size.old
      new += size.new
      position = window.upperBound
    }
    return output
  }

  private static func counts(_ steps: ArraySlice<Step>) -> (old: Int, new: Int) {
    (steps.filter { $0.prefix != "+" }.count, steps.filter { $0.prefix != "-" }.count)
  }
}
