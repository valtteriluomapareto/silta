import Foundation

/// Reads stored document snapshots without Git, writes or resolving historical targets.
package struct DocService {
  let workspace: String
  let store: DatabaseStore

  /// Uses one explicit workspace and command-scoped storage.
  package init(workspace: String, store: DatabaseStore) {
    self.workspace = workspace
    self.store = store
  }

  /// Reads a current or explicit revision, masking before rendered-line selection.
  package func show(_ ref: String, revision: Int? = nil, lines: String? = nil) throws
    -> DocReadResult
  {
    let selection = try Self.selection(ref, revision: revision)
    let range = try Self.lineRange(lines)
    do {
      let stored = try read(selection.slug, revision: selection.revision)
      let ref: String
      let text: String
      if let snapshot = stored.revision {
        ref = "doc:\(snapshot.slug)@\(snapshot.revision)"
        let state = snapshot.state + (stored.archived ? ", archived" : "")
        text =
          "\(ref) [\(state)]\n"
          + "title: \(snapshot.title ?? "(unknown)")\nkind: \(snapshot.kind ?? "(unknown)")\n"
          + "about: \(Self.about(snapshot.about))\nactor: \(snapshot.actor)\n"
          + "created_at: \(snapshot.createdAt)\n\n\(snapshot.body)"
      } else {
        ref = "doc:" + selection.slug
        text =
          "No accepted revision for \(ref).\nPending revisions (\(stored.pendingCount)):\n"
          + stored.pending.map { "\(ref)@\($0)\n" }.joined()
          + (stored.pendingCount > stored.pending.count && scopeIsSafe && Self.safeReference(ref)
            ? "next: " + listCommand + "\n" : "")
      }
      return DocReadResult(
        masking: ref, output: bounded(SecretGuard.redacted(text), ref: ref, range: range))
    } catch let error as DocError {
      throw CommandFailure(error: error, next: [listCommand])
    }
  }

  var scopeIsSafe: Bool { SecretGuard.matches(in: workspace).isEmpty }

  var listCommand: String {
    scopeIsSafe ? workspaceCommand("silta doc ls", workspace: workspace) : "silta ws ls"
  }

  var configurationCommand: String {
    scopeIsSafe ? workspaceCommand("silta ws show", workspace: workspace) : "silta ws ls"
  }

  func listPageCommand(about: String?, archived: Bool, offset: Int, limit: Int) -> String {
    guard scopeIsSafe, about.map(Self.safeReference) ?? true else { return listCommand }
    var command = listCommand
    if let about { command += " --about " + shellWord(about) }
    if archived { command += " --archived" }
    return command + " --offset \(offset) --limit \(limit)"
  }

  func showCommand(_ ref: String, lines: String? = nil) -> String {
    guard scopeIsSafe, Self.safeReference(ref) else { return listCommand }
    return workspaceCommand("silta doc show " + shellWord(ref), workspace: workspace)
      + (lines.map { " --lines " + $0 } ?? "")
  }

  static func about(_ refs: [String]?) -> String {
    refs.map {
      $0.isEmpty
        ? "(none)"
        : $0.map { ref in
          safeReference(ref) ? ref : SecretGuard.redacted(ref.removingPercentEncoding ?? ref)
        }.joined(separator: ", ")
    } ?? "(unknown)"
  }

  static func safeReference(_ ref: String) -> Bool {
    SecretGuard.matches(in: ref.removingPercentEncoding ?? ref).isEmpty
  }

  static func preview(_ raw: String) -> String {
    let text = SecretGuard.redacted(raw).components(separatedBy: .newlines).joined(separator: " ")
    guard text.count > 120 else { return text }
    return String(text.prefix(120)) + " [\(text.count - 120) characters omitted]"
  }

  private func bounded(_ text: String, ref: String, range: ClosedRange<Int>?) -> String {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let first = range?.lowerBound ?? 1
    let last = min(range?.upperBound ?? lines.count, lines.count)
    guard first <= last else {
      return "Document has \(lines.count) rendered lines; selection is past the end.\n"
        + "next: " + showCommand(ref) + "\n"
    }
    let count = last - first + 1
    let unsafe = !scopeIsSafe || !Self.safeReference(ref)
    let shown = min(count, count > 400 || unsafe ? 399 : 400)
    let output = lines.dropFirst(first - 1).prefix(shown).joined(separator: "\n") + "\n"
    guard shown < count else {
      return output + (unsafe ? "next: " + listCommand + "\n" : "")
    }
    return output + "\(count - shown) lines omitted; next: "
      + showCommand(ref, lines: "\(first + shown)-\(last)") + "\n"
  }

  private static func lineRange(_ raw: String?) throws -> ClosedRange<Int>? {
    guard let raw else { return nil }
    let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let start = Int(parts[0]), start > 0,
      let end = parts.last.flatMap({ Int($0) }), end >= start,
      parts.map(String.init).joined(separator: "-")
        == (parts.count == 1 ? "\(start)" : "\(start)-\(end)")
    else {
      throw UsageError.usage(
        message: "--lines must be a positive line N or inclusive range A-B.",
        command: "silta doc show")
    }
    return start...end
  }

  private static func selection(_ raw: String, revision: Int?) throws
    -> (slug: String, revision: Int?)
  {
    let value = raw.hasPrefix("doc:") ? String(raw.dropFirst(4)) : raw
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count <= 2, let slug = parts.first, WorkspaceConfig.isValidIdentifier(String(slug)),
      revision.map({ $0 > 0 }) ?? true
    else {
      throw UsageError.usage(
        message: "Use a doc slug or doc:slug@revision.", command: "silta doc show")
    }
    var selected = revision
    if parts.count == 2 {
      guard let number = Int(parts[1]), number > 0, String(number) == parts[1] else {
        throw UsageError.usage(message: "Use a positive revision.", command: "silta doc show")
      }
      guard revision == nil || revision == number else {
        throw UsageError.usage(
          message: "--rev conflicts with the revision in the ref.", command: "silta doc show")
      }
      selected = number
    }
    return (String(slug), selected)
  }
}
