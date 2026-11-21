import Foundation
import GRDB

/// Checks edge references with short, local-only reads. Each distinct reference is
/// probed at most once per command.
package struct EdgeCodeEvidence {
  private static let limit = 16
  private let reader: CodeService
  private let workspace: String
  private var outcomes: [Data: Outcome] = [:]
  private var stoppedForTimeout = false

  private static let unverified = "edge_code_unverified"

  private enum Outcome {
    case verified(String)
    case timedOut
    case skippedAfterTimeout
    case unavailable
    case unsafe
  }

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
    guard case .verified(let command) = await outcome(raw) else { return nil }
    return command
  }

  private mutating func outcome(_ raw: String) async -> Outcome? {
    let key = Data(raw.utf8)
    if let previous = outcomes[key] { return previous }
    guard outcomes.count < Self.limit, !Task.isCancelled else { return nil }
    let result = stoppedForTimeout ? .skippedAfterTimeout : await verify(raw)
    if case .timedOut = result { stoppedForTimeout = true }
    outcomes[key] = result
    return result
  }

  private func verify(_ raw: String) async -> Outcome {
    guard let (target, operation) = Self.parse(raw) else { return .unsafe }
    do {
      guard try await reader.validateEvidence(operation, target: target) else {
        return .unavailable
      }
      return .verified(operation.command(workspace: workspace, target: target, prod: false))
    } catch CodeError.timeout {
      return .timedOut
    } catch {
      return .unavailable
    }
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
    for reference in references where probe.outcomes[Data(reference.utf8)] == nil {
      guard let result = await probe.outcome(reference) else {
        let code = probe.stoppedForTimeout ? Self.unverified : "edge_code_unavailable"
        warnings.append(probe.warning("Some edge code references were not checked.", code: code))
        break
      }
      switch result {
      case .verified: break
      case .unsafe:
        warnings.append(
          probe.warning("An edge code reference could not be read or printed safely."))
      case .timedOut:
        warnings.append(
          probe.referenceWarning(
            reference, "could not be verified locally (Git timed out).", code: Self.unverified))
      case .skippedAfterTimeout:
        warnings.append(
          probe.referenceWarning(
            reference, "was not checked after a Git timeout.", code: Self.unverified))
      case .unavailable:
        warnings.append(probe.referenceWarning(reference, "is unavailable locally."))
      }
    }
    return warnings
  }

  private func referenceWarning(
    _ reference: String, _ detail: String, code: String = "edge_code_unavailable"
  ) -> OutputWarning {
    let name = String(HumanText.line(reference).prefix(160)).debugDescription
    return warning("Edge code reference " + name + " " + detail, code: code)
  }

  private func warning(_ message: String, code: String = "edge_code_unavailable") -> OutputWarning {
    .init(code: code, message: message + " Inspect it with " + inspect + ".")
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
