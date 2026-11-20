import Foundation
import GRDB

/// Checks edge references with short, local-only reads. Each distinct reference is
/// probed at most once per command.
package struct EdgeCodeEvidence {
  private static let limit = 16
  private let reader: CodeService
  private let workspace: String
  private var attempted: Set<Data> = []
  private var commands: [Data: String] = [:]

  init(workspace: String, environment: SiltaEnvironment, git: any GitRunner) {
    self.workspace = workspace
    reader = CodeService(
      workspace: workspace, store: environment.db, git: git,
      at: environment.clock.now(), localOnly: true)
  }

  var inspect: String { "silta --ws " + shellWord(workspace) + " ws show" }

  static func references(_ stored: String) -> [String] {
    let decoded = try? JSONSerialization.jsonObject(with: Data(stored.utf8))  // Invalid evidence.
    guard let values = decoded as? [Any] else { return [] }
    return values.compactMap { $0 as? String }
  }

  mutating func command(_ raw: String) async -> String? {
    let key = Data(raw.utf8)
    if attempted.contains(key) { return commands[key] }
    guard attempted.count < Self.limit, !Task.isCancelled else { return nil }
    attempted.insert(key)
    guard let (target, operation) = Self.parse(raw) else { return nil }
    let available = try? await reader.validateEvidence(operation, target: target)  // Unavailable.
    guard available == true else { return nil }
    let command = operation.command(workspace: workspace, target: target, prod: false)
    commands[key] = command
    return command
  }

  /// Reports unresolved references after the workspace edit transaction commits.
  package static func warnings(workspace: String, environment: SiltaEnvironment) async
    -> [OutputWarning]
  {
    var probe = Self(workspace: workspace, environment: environment, git: environment.git)
    let references: [String]
    do {
      references = try environment.db.read { db in
        let id = try TaskService.workspaceID(workspace, in: db)
        let encoded = try String.fetchAll(
          db, sql: "SELECT code_refs FROM edge WHERE workspace_id=? ORDER BY id", arguments: [id])
        return encoded.flatMap(Self.references)
      }
    } catch {
      return [probe.warning("Could not inspect saved edge code references.")]
    }
    var warnings: [OutputWarning] = []
    for reference in references where !probe.attempted.contains(Data(reference.utf8)) {
      guard probe.attempted.count < Self.limit, !Task.isCancelled else {
        warnings.append(probe.warning("Some edge code references were not checked."))
        break
      }
      if await probe.command(reference) == nil {
        let detail =
          if Self.parse(reference) != nil {
            "Edge code reference "
              + String(HumanText.line(reference).prefix(160)).debugDescription
              + " is unavailable locally."
          } else {
            "An edge code reference could not be read or printed safely."
          }
        warnings.append(probe.warning(detail))
      }
    }
    return warnings
  }

  private func warning(_ message: String) -> OutputWarning {
    .init(code: "edge_code_unavailable", message: message + " Inspect it with " + inspect + ".")
  }

  private static func parse(_ raw: String) -> (String, CodeRead)? {
    let value = raw.hasPrefix("code:") ? String(raw.dropFirst(5)) : raw
    guard let colon = value.firstIndex(of: ":"), colon != value.startIndex,
      (try? TaskLinkTarget.storedCodeApp(value)) != nil  // Invalid evidence has no command.
    else { return nil }
    let target = String(value[..<colon])
    let file = value[value.index(after: colon)...].split(separator: "#", maxSplits: 1)
    guard let leaf = file.first else { return nil }
    let path = String(leaf)
    guard RestoreService.canNameInRecovery(target), RestoreService.canNameInRecovery(path)
    else { return nil }
    let lines = file.count == 2 ? String(file[1].dropFirst()) : nil
    return (target, .show(path, lines: lines))
  }
}
