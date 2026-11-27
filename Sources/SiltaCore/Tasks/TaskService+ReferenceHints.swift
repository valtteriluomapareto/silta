import Foundation
import GRDB

extension TaskService {
  static let referenceHintMarker = "hinted task "

  /// Advisory receipts opt in so callers that discard warnings leave the hint available.
  func taskReferenceWarnings(
    _ texts: [String], task: @autoclosure () throws -> TaskDetails, workspace: String,
    at: Date, in tx: StorageTransaction
  ) -> [OutputWarning] {
    guard referenceHints, RestoreService.canNameInRecovery(workspace) else { return [] }
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
          try event(
            "field", task: source.id, body: Self.referenceHintMarker + target.uid, at: at, in: tx)
          warnings.append(Self.referenceWarning(from: source, to: target, workspace: workspace))
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
      let visible = SecretGuard.redacted(String(text.prefix(16_384)))
      let lines = visible.components(separatedBy: "\n")
      for index in MarkdownPlan.visibleLines(lines) {
        let line = lines[index]
        let content = line.drop(while: { $0 == " " })
        if line.hasPrefix("    ") || content.hasPrefix("\t") || content.hasPrefix(">") { continue }
        for word in line.split(whereSeparator: \.isWhitespace) where !word.contains("://") {
          for token in word.split(whereSeparator: { !taskTokenCharacter($0) }) {
            guard token.hasPrefix(prefix),
              let seq = Int64(token.dropFirst(prefix.count)), seq > 0,
              token == prefix + String(seq)
            else { continue }
            let ref = String(token)
            if seen.insert(ref).inserted { refs.append(ref) }
            if refs.count == 32 { return refs }
          }
        }
      }
    }
    return refs
  }

  private static func taskTokenCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
      || character == "/"
  }

  private func unrelatedTarget(
    _ ref: String, from source: TaskDetails, workspace: String, in db: Database
  ) throws -> TaskDetails? {
    guard RestoreService.canNameInRecovery(ref) else { return nil }
    let target: TaskDetails
    do { target = try Self.lookup(ref, workspace: workspace, in: db) } catch TaskError.notFound {
      return nil
    }
    guard source.parent != target.ref, target.parent != source.ref,
      target.status != "proposed" || target.createdBy == environment.actor.description
        || environment.actor.isHuman
    else { return nil }
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
        "marker": Self.referenceHintMarker + target.uid,
      ])
    return linkedOrHinted == true ? nil : target
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
