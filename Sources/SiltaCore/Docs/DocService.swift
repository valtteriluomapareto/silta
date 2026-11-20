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

  /// Reads a stored body, recorded-base diff or comments, masking before line selection.
  package func show(
    _ ref: String, revision: Int? = nil, lines: String? = nil, diff: Bool = false,
    comments: Bool = false, offset: Int? = nil, limit: Int? = nil
  ) throws -> DocReadResult {
    let request = try DocReadView.parse(
      ref, diff: diff, comments: comments, offset: offset, limit: limit)
    let selection = try Self.selection(request.ref, revision: revision)
    let range = try Self.lineRange(lines)
    do {
      let result = try read(selection.slug, revision: selection.revision, view: request.view)
      let matches = SecretGuard.matches(in: result.output)
      let masked = SecretGuard.redacted(result.output, matches: matches)
      let window = bounded(masked, ref: result.ref, flags: request.view.flags, range: range)
      var selected = DocReadResult(ref: SecretGuard.redacted(result.ref), output: window.output)
      selected.metadata = result.metadata
      guard
        let rendered = String(
          bytes: masked.utf8.dropFirst(window.visible.lowerBound).prefix(window.visible.count),
          encoding: .utf8)
      else { throw StorageError.internalMisuse }
      selected.rendered = rendered
      selected.nextLine = window.nextLine
      result.bodyLayout?.project(
        matches: matches, masked: masked, visible: window.visible, into: &selected)
      return selected
    } catch let error as DocError {
      throw CommandFailure(
        error: error,
        next: [listPageCommand(about: nil, archived: true, offset: 0, limit: 20)])
    }
  }

  func body(_ snapshot: DocRevision, archived: Bool, pending: Int) -> DocReadResult {
    let pinned = "doc:\(snapshot.slug)@\(snapshot.revision)"
    let hint =
      pending > 0
      ? "; \(pending) pending: "
        + listPageCommand(
          about: nil, archived: archived, offset: 0, limit: 20, document: snapshot.slug) : ""
    var layout = DocBodyLayout()
    layout.append("\(pinned) [")
    layout.state = layout.field(snapshot.state)
    layout.append((archived ? ", archived" : "") + "]\(hint)\ntitle: ")
    let title = layout.field(snapshot.title ?? "(unknown)")
    layout.title = snapshot.title == nil ? nil : title
    layout.append("\nkind: \(snapshot.kind ?? "(unknown)")\nabout: ")
    let aboutStart = layout.output.utf8.count
    if let refs = snapshot.about {
      layout.about = []
      if refs.isEmpty {
        layout.append("(none)")
      } else {
        for (index, ref) in refs.enumerated() {
          if index > 0 { layout.append(", ") }
          let field = layout.field(Self.referenceForMasking(ref))
          layout.about?.append(field)
        }
      }
    } else {
      layout.append("(unknown)")
    }
    layout.aboutField = aboutStart..<layout.output.utf8.count
    layout.append("\nactor: \(snapshot.actor)\ncreated_at: \(snapshot.createdAt)\n")
    layout.append(Self.evidence(snapshot) + "\n")
    layout.body = layout.field(snapshot.body)
    var result = DocReadResult(ref: pinned, output: layout.output, bodyLayout: layout)
    result.metadata = Self.displayMetadata(snapshot, archived: archived)
    return result
  }

  /// Composes evidence for masking with the surrounding document fields.
  static func evidence(_ snapshot: DocRevision) -> String {
    let why: String
    switch snapshot.message {
    case nil: why = "why: (not recorded)\n"
    case "": why = "why: (empty)\n"
    case .some(let text):
      why =
        "why:\n"
        + text.components(separatedBy: "\n")
        .map { "  " + $0 }.joined(separator: "\n") + "\n"
    }
    return "source_task: " + (snapshot.sourceTask.map(referenceForMasking) ?? "(not recorded)")
      + "\n"
      + "triaged_by: \(snapshot.triagedBy ?? "(not recorded)")\n"
      + "triaged_at: \(snapshot.triagedAt ?? "(not recorded)")\n" + why
  }

  package static func documentFilter(_ raw: String?) throws -> String? {
    guard let raw else { return nil }
    let selected: (slug: String, revision: Int?)?
    do { selected = try selection(raw, revision: nil) } catch { selected = nil }
    guard let selected, selected.revision == nil else {
      throw CommandFailure(
        error: DocError.invalid("Use an unpinned doc slug or doc:slug with --doc."),
        next: ["silta doc ls --help"])
    }
    return selected.slug
  }

  var scopeIsSafe: Bool { SecretGuard.matches(in: workspace).isEmpty }

  var listCommand: String {
    scopeIsSafe ? workspaceCommand("silta doc ls", workspace: workspace) : "silta ws ls"
  }

  var configurationCommand: String {
    scopeIsSafe ? workspaceCommand("silta ws show", workspace: workspace) : "silta ws ls"
  }

  func listPageCommand(
    about: String?, archived: Bool, offset: Int, limit: Int,
    document: String? = nil
  ) -> String {
    Self.listPageCommand(
      workspace: workspace, about: about, archived: archived,
      offset: offset, limit: limit, document: document)
  }

  static func listPageCommand(
    workspace: String, about: String?, archived: Bool,
    offset: Int, limit: Int, document: String? = nil
  ) -> String {
    let scope = SecretGuard.matches(in: workspace).isEmpty
    let hub = scope ? workspaceCommand("silta doc ls", workspace: workspace) : "silta ws ls"
    let fallback = document != nil && archived && scope ? hub + " --archived" : hub
    let boundedHub = fallback.utf8.count <= 512 ? fallback : "silta ws ls"
    guard scope, about.map(Self.safeReference) ?? true,
      document.map({ Self.safeReference("doc:" + $0) }) ?? true
    else { return document == nil ? hub : boundedHub }
    var command = hub
    if let document { command += " --doc " + shellWord(document) }
    if let about { command += " --about " + shellWord(about) }
    if archived { command += " --archived" }
    command += " --offset \(offset) --limit \(limit)"
    return document != nil && command.utf8.count > 512 ? boundedHub : command
  }

  func showCommand(_ ref: String, flags: String = "", lines: String? = nil) -> String {
    guard scopeIsSafe, Self.safeReference(ref) else { return listCommand }
    do {
      let parsed = try DocReadView.parse(ref, diff: false, comments: false, offset: nil, limit: nil)
      _ = try Self.selection(parsed.ref, revision: nil)
    } catch {
      return listPageCommand(about: nil, archived: true, offset: 0, limit: 20)
    }
    return workspaceCommand("silta doc show " + shellWord(ref), workspace: workspace) + flags
      + (lines.map { " --lines " + $0 } ?? "")
  }

  static func about(_ refs: [String]?) -> String {
    SecretGuard.redacted(aboutForMasking(refs))
  }

  /// Keeps the reference spans intact until their complete containing text is masked.
  static func aboutForMasking(_ refs: [String]?) -> String {
    refs.map {
      $0.isEmpty
        ? "(none)"
        : $0.map(referenceForMasking).joined(separator: ", ")
    } ?? "(unknown)"
  }

  private static func referenceForMasking(_ ref: String) -> String {
    let decoded = ref.removingPercentEncoding ?? ref
    return SecretGuard.matches(in: decoded).isEmpty ? ref : decoded
  }

  static func displayReference(_ ref: String) -> String {
    safeReference(ref) ? ref : SecretGuard.redacted(ref.removingPercentEncoding ?? ref)
  }

  static func safeReference(_ ref: String) -> Bool {
    SecretGuard.matches(in: ref.removingPercentEncoding ?? ref).isEmpty
  }

  static func preview(_ raw: String) -> String {
    let text = SecretGuard.redacted(raw).components(separatedBy: .newlines).joined(separator: " ")
    guard text.count > 120 else { return text }
    return String(text.prefix(120)) + " [\(text.count - 120) characters omitted]"
  }

  private func bounded(
    _ text: String, ref: String, flags: String, range: ClosedRange<Int>?
  ) -> DocReadWindow {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let first = range?.lowerBound ?? 1
    let last = min(range?.upperBound ?? lines.count, lines.count)
    guard first <= last else {
      return DocReadWindow(
        output:
          "Document has \(lines.count) rendered lines; selection is past the end.\n"
          + "next: " + showCommand(ref, flags: flags) + "\n", visible: 0..<0, nextLine: nil
      )
    }
    let count = last - first + 1
    let unsafe = !scopeIsSafe || !Self.safeReference(ref)
    let shown = min(count, count > 400 || unsafe ? 399 : 400)
    let output = lines.dropFirst(first - 1).prefix(shown).joined(separator: "\n") + "\n"
    let start = lines.prefix(first - 1).reduce(0) { $0 + $1.utf8.count + 1 }
    let visible = start..<min(text.utf8.count, start + output.utf8.count)
    guard shown < count else {
      return DocReadWindow(
        output: output + (unsafe ? "next: " + listCommand + "\n" : ""), visible: visible,
        nextLine: nil)
    }
    return DocReadWindow(
      output:
        output + "\(count - shown) lines omitted; next: "
        + showCommand(ref, flags: flags, lines: "\(first + shown)-\(last)") + "\n",
      visible: visible,
      nextLine: first + shown
    )
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

  static func selection(_ raw: String, revision: Int?) throws
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

private struct DocReadWindow {
  let output: String
  let visible: Range<Int>
  let nextLine: Int?
}
