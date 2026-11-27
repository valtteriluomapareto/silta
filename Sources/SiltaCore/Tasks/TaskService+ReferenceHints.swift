import CryptoKit
import Foundation
import GRDB

extension TaskService {
  static let referenceHintMarker = "hinted task "

  /// Mask retained secrets before limiting text, without holding the writer lock.
  func referenceHintText(_ texts: [String], allowSecret: Bool) -> [String] {
    guard referenceHints else { return [] }
    return texts.map { raw in
      let text = allowSecret ? SecretGuard.redacted(raw) : raw
      let head = text.prefix(16_384)
      if head.endIndex == text.endIndex || text[head.endIndex].isWhitespace {
        return String(head)
      }
      return head.lastIndex(where: \.isWhitespace).map { String(head[..<$0]) } ?? ""
    }
  }

  /// Advisory receipts opt in so callers that discard warnings leave the hint available.
  func taskReferenceWarnings(
    _ texts: [String], task: @autoclosure () throws -> TaskDetails, workspace: String,
    at: Date, in tx: StorageTransaction
  ) -> [OutputWarning] {
    guard !texts.allSatisfy(\.isEmpty), RestoreService.canNameInRecovery(workspace) else {
      return []
    }
    var warnings: [OutputWarning] = []
    do {
      try tx.database.inSavepoint {
        let source = try task()
        guard RestoreService.canNameInRecovery(source.ref),
          try foreignClaim(source, at: at) == nil,
          let delimiter = source.ref.lastIndex(of: "-")
        else { return .commit }
        let prefix = source.ref[...delimiter]
        for ref in Self.mentionedTasks(texts, prefix: prefix) where ref != source.ref {
          guard
            let target = try unrelatedTarget(
              ref, from: source, workspace: workspace, in: tx.database)
          else { continue }
          try event("field", task: source.id, body: target.marker, at: at, in: tx)
          warnings.append(
            Self.referenceWarning(from: source, to: target.task, workspace: workspace))
          if warnings.count == 3 { break }
        }
        return .commit
      }
    } catch {
      return []
    }
    return warnings
  }

  private static func mentionedTasks(_ texts: [String], prefix: Substring) -> [String] {
    var seen = Set<String>()
    var refs: [String] = []
    for text in texts {
      let lines = text.components(separatedBy: "\n")
      for index in MarkdownPlan.visibleLines(lines) {
        let line = lines[index]
        let content = line.drop(while: { $0 == " " })
        if line.hasPrefix("    ") || content.hasPrefix("\t") || content.hasPrefix(">") { continue }
        for word in line.split(whereSeparator: \.isWhitespace) {
          guard let prose = proseToken(word) else { continue }
          for token in prose.split(whereSeparator: { !taskTokenCharacter($0) }) {
            let typed = token.hasPrefix("task:") ? token.dropFirst(5) : token
            let ref = typed.last == ":" ? typed.dropLast() : typed
            guard ref.hasPrefix(prefix),
              let seq = Int64(ref.dropFirst(prefix.count)), seq > 0,
              ref == prefix + String(seq)
            else { continue }
            let canonical = String(ref)
            if seen.insert(canonical).inserted { refs.append(canonical) }
            if refs.count == 32 { return refs }
          }
        }
      }
    }
    return refs
  }

  private static func proseToken(_ word: Substring) -> Substring? {
    if word.hasPrefix("["), let destination = word.range(of: "](") {
      return word[..<destination.lowerBound]
    }
    let candidate = word.drop(while: { !$0.isLetter }).lowercased()
    guard !word.contains("://"), !candidate.hasPrefix("mailto:"), !candidate.hasPrefix("urn:")
    else { return nil }
    return word
  }

  private static func taskTokenCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
      || character == "/" || character == ":"
  }

  private func unrelatedTarget(
    _ ref: String, from source: TaskDetails, workspace: String, in db: Database
  ) throws -> (task: TaskDetails, marker: String)? {
    guard RestoreService.canNameInRecovery(ref) else { return nil }
    let target: TaskDetails
    do { target = try Self.lookup(ref, workspace: workspace, in: db) } catch TaskError.notFound {
      return nil
    }
    guard source.parent != target.ref, target.parent != source.ref,
      target.status != "proposed" || target.createdBy == environment.actor.description
        || environment.actor.isHuman
    else { return nil }
    let marker =
      Self.referenceHintMarker
      + SHA256.hash(data: Data(target.uid.utf8)).map { String(format: "%02x", $0) }.joined()
    let linkedOrHinted = try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM link
          WHERE workspace_id=:workspace AND from_kind='task' AND to_kind='task'
            AND ((from_id=:source AND to_id=:target) OR (from_id=:target AND to_id=:source))
          UNION ALL
          SELECT 1 FROM task_event
          WHERE task_id=:source AND kind='field' AND body=:marker
        )
        """,
      arguments: [
        "workspace": source.workspaceID, "source": source.id, "target": target.id,
        "marker": marker,
      ])
    return linkedOrHinted == true ? nil : (target, marker)
  }

  private static func referenceWarning(
    from source: TaskDetails, to target: TaskDetails, workspace: String
  ) -> OutputWarning {
    let scope = "silta --ws " + shellWord(workspace) + " task "
    let ref = shellWord(source.ref)
    let destination = shellWord("task:" + target.ref)
    let blocker =
      if ["todo", "doing", "review", "blocked"].contains(source.status),
        ["todo", "doing", "review", "blocked"].contains(target.status), target.externalRef == nil
      {
        " If it blocks progress, use `\(scope)block \(ref) --on \(destination) -F -` "
          + "and supply the reason on stdin."
      } else {
        ""
      }
    return OutputWarning(
      code: "task_ref_unlinked",
      message: "\(source.ref) names \(target.ref) without a task relationship. If related, "
        + "use `\(scope)link \(ref) \(destination) --rel relates`." + blocker)
  }
}
