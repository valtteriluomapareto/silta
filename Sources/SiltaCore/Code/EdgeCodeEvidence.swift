import Foundation
import GRDB

/// Checks edge references with short, local-only reads. Each distinct reference is
/// probed at most once per command.
package struct EdgeCodeEvidence {
  private static let limit = 16
  private let reader: CodeService
  private let workspace: String
  private var attempted: Set<String> = []
  private var commands: [String: String] = [:]

  init(workspace: String, environment: SiltaEnvironment) {
    self.workspace = workspace
    reader = CodeService(
      workspace: workspace, store: environment.db, git: environment.git,
      at: environment.clock.now(), localOnly: true)
  }

  var inspect: String { "silta --ws " + shellWord(workspace) + " ws show" }

  static func references(_ stored: String) -> [String] {
    let decoded = try? JSONSerialization.jsonObject(with: Data(stored.utf8))  // Invalid evidence.
    guard let values = decoded as? [Any] else { return [] }
    return values.compactMap { $0 as? String }
  }

  mutating func command(_ raw: String) async -> String? {
    if attempted.contains(raw) { return commands[raw] }
    guard attempted.count < Self.limit, !Task.isCancelled else { return nil }
    attempted.insert(raw)
    guard let (target, operation) = Self.parse(raw) else { return nil }
    let available = try? await reader.validateEvidence(operation, target: target)  // Unavailable.
    guard available == true else { return nil }
    let command = operation.command(workspace: workspace, target: target, prod: false)
    commands[raw] = command
    return command
  }

  /// Reports unresolved references after the workspace edit transaction commits.
  package static func warnings(workspace: String, environment: SiltaEnvironment) async
    -> [OutputWarning]
  {
    var probe = Self(workspace: workspace, environment: environment)
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
    for reference in references where !probe.attempted.contains(reference) {
      guard probe.attempted.count < Self.limit, !Task.isCancelled else {
        warnings.append(probe.warning("Some edge code references were not checked."))
        break
      }
      if await probe.command(reference) == nil {
        let label = HumanText.line(reference).prefix(160)
        warnings.append(
          probe.warning(
            "Edge code reference \(String(label).debugDescription) is unavailable locally."))
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
    guard let path = file.first else { return nil }
    let lines = file.count == 2 ? String(file[1].dropFirst()) : nil
    return (target, .show(String(path), lines: lines))
  }
}
