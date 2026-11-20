import CryptoKit
package import Foundation
import GRDB

/// Runs an approved editing loop over a temporary YAML view.
package enum WorkspaceEditor {
  /// Requires the human's go-ahead before reading configuration or invoking the editor.
  /// Returns nil on unchanged input or a nonzero editor exit, leaving storage untouched.
  package static func edit(
    slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date), approved: String? = nil,
    prepared: Result<String?, any Error>? = nil, editor: (URL) throws -> Int32
  ) throws -> String? {
    let command = approvalCommand(slug)
    let approval = try actor.requireHuman(command: command + " -F <file>", approved: approved)
    let baseline = try capture(slug: slug, store: store, prepared: prepared)
    return try editCaptured(
      baseline, store: store, identity: identity, approval: (approval, command), editor: editor)
  }

  /// Renders a saved snapshot with the baseline required to apply it.
  package static func snapshot(slug: String, store: DatabaseStore) throws -> String {
    let baseline = try capture(slug: slug, store: store, prepared: nil)
    return baseline.stamped(baseline.text)
  }

  /// Captures the configuration before evaluating the supplied YAML input.
  package static func apply(
    _ input: @autoclosure () throws -> String, slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date), approved: String? = nil,
    prepared: Result<String?, any Error>? = nil, retryFromStdin: Bool = false
  ) throws -> String? {
    let base = approvalCommand(slug)
    let command = base + " -F <file>"
    let retry = retryFromStdin ? base + " -F -" : command
    let approval = try actor.requireHuman(command: retry, approved: approved)
    let captured = Result { try capture(slug: slug, store: store, prepared: prepared) }
    let document = try input()
    try BoundedInput.requireNoNul(document)
    let workspace = (try? captured.get())?.slug ?? slug  // Only scopes malformed input recovery.
    let (stamp, text) = try Baseline.payload(document, workspace: workspace)
    let baseline: Baseline
    do { baseline = try captured.get() } catch let error as WorkspaceError
      where error.code == .notFound && slug == nil && stamp == "new"
    {
      throw WorkspaceEditConflict(workspace: nil)
    }
    try baseline.check(stamp: stamp)
    let config = try WorkspaceConfig.parse(text, keepingAppNames: baseline.appNames)
    if baseline.slug != nil, text.utf8.elementsEqual(baseline.text.utf8) {
      try store.read(baseline.check)
      return nil
    }
    return try save(
      config, baseline: baseline, store: store, identity: identity,
      approval: (approval, command))
  }

  private struct Baseline {
    let slug: String?
    let uid: String?
    let text: String
    /// Unchanged legacy labels can survive an edit without relaxing validation of new text.
    let appNames: [String: String]

    private static let marker = "# silta-base:"
    private static let prefix = marker + " "

    private var token: String {
      guard let uid else { return "new" }
      return SHA256.hash(data: Data((uid + "\0" + text).utf8))
        .map { String(format: "%02x", $0) }.joined()
    }

    func stamped(_ document: String) -> String {
      Self.prefix + token + "\n" + document
    }

    static func payload(_ document: String, workspace: String?) throws
      -> (stamp: Substring?, text: String)
    {
      let headers = baselineHeaders(in: document)
      guard let header = headers.first else { return (nil, document) }
      let invalidStamp = CommandFailure(
        error: WorkspaceError.invalid(["line 1: malformed workspace baseline"]),
        next: [workspaceEditRead(workspace)])
      guard headers.count == 1, document.hasPrefix(header), header.hasPrefix(Self.prefix),
        let newline = document.utf8.firstIndex(of: 0x0A)
      else { throw invalidStamp }
      let supplied = header.dropFirst(Self.prefix.count)
      guard supplied == "new" || supplied.wholeMatch(of: /[0-9a-f]{64}/) != nil
      else { throw invalidStamp }
      let text = String(document[document.utf8.index(after: newline)...])
      return (supplied, text)
    }

    private static func baselineHeaders(in document: String) -> [Substring] {
      var leading = true
      return document.split(whereSeparator: \.isNewline).filter { line in
        let candidate = leading ? line.drop(while: headerWhitespace) : line
        guard candidate.first == "#" else {
          if !candidate.isEmpty { leading = false }
          return false
        }
        let comment = candidate.dropFirst().drop(while: headerWhitespace)
        return comment == "silta-base" || comment.hasPrefix("silta-base:")
      }
    }

    private static func headerWhitespace(_ character: Character) -> Bool {
      character == " " || character == "\t" || character == "\u{FEFF}"
    }

    func check(stamp: Substring?) throws {
      if let stamp, stamp != token { throw WorkspaceEditConflict(workspace: slug) }
    }

    func check(in db: Database) throws {
      if let slug {
        let current = try WorkspaceEditor.uid(in: db, slug: slug)
        guard current == uid,
          try WorkspaceConfig.render(from: db, slug: slug).utf8.elementsEqual(text.utf8)
        else {
          throw WorkspaceEditConflict(workspace: current == nil ? nil : slug)
        }
      } else {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM workspace LIMIT 1") == nil else {
          throw WorkspaceEditConflict(workspace: nil)
        }
      }
    }
  }

  private static func approvalCommand(_ slug: String?) -> String {
    "silta ws edit" + (slug.map { " " + shellWord($0) } ?? "")
  }

  private static func uid(in db: Database, slug: String) throws -> String? {
    try String.fetchOne(db, sql: "SELECT uid FROM workspace WHERE slug=?", arguments: [slug])
  }

  private static func capture(
    slug: String?, store: DatabaseStore, prepared: Result<String?, any Error>?
  ) throws -> Baseline {
    if slug == nil {
      _ = try prepared?.get()
      if try WorkspaceSelection.list(in: store).isEmpty {
        return Baseline(
          slug: nil, uid: nil, text: "workspace: {slug: acme, name: Acme, task_prefix: AC}\n",
          appNames: [:])
      }
    }
    let selected = try WorkspaceSelection.resolve(slug, in: store, prepared: prepared)
    return try store.read { db in
      guard let uid = try uid(in: db, slug: selected) else {
        throw WorkspaceError.unknown(selected)
      }
      let appNames = try Row.fetchAll(
        db,
        sql: """
          SELECT app.slug,app.name FROM app JOIN workspace ON workspace.id=app.workspace_id
          WHERE workspace.slug=?
          """, arguments: [selected]
      ).reduce(into: [String: String]()) { names, row in
        let app: String = row["slug"]
        if WorkspaceConfig.isValidIdentifier(app) { names[app] = row["name"] }
      }
      return Baseline(
        slug: selected, uid: uid, text: try WorkspaceConfig.render(from: db, slug: selected),
        appNames: appNames)
    }
  }

  private static func editCaptured(
    _ baseline: Baseline, store: DatabaseStore, identity: (ids: any IDGenerator, date: Date),
    approval: (HumanApproval?, String), editor: (URL) throws -> Int32
  ) throws -> String? {
    do {
      let manager = FileManager.default
      let directory = try manager.url(
        for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: manager.temporaryDirectory, create: true)
      var retain = false
      defer {
        if !retain { try? manager.removeItem(at: directory) }  // best-effort temporary cleanup
      }
      try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let file = directory.appending(path: "workspace.yaml")
      var content = baseline.text
      var rejected: (text: String, error: WorkspaceError)?
      while true {
        try content.write(to: file, atomically: true, encoding: .utf8)
        guard try editor(file) == 0 else { return nil }
        let changed = try String(contentsOf: file, encoding: .utf8)
        try BoundedInput.requireNoNul(changed)
        let unchanged = changed.utf8.elementsEqual(content.utf8)
        if let rejected, unchanged || changed.utf8.elementsEqual(rejected.text.utf8) {
          throw unchangedFailure(rejected.error, baseline: baseline)
        }
        let (stamp, text) = try Baseline.payload(changed, workspace: baseline.slug)
        do {
          try baseline.check(stamp: stamp)
          let config = try WorkspaceConfig.parse(text, keepingAppNames: baseline.appNames)
          guard !unchanged else { return nil }
          return try save(
            config, baseline: baseline, store: store, identity: identity, approval: approval)
        } catch var conflict as WorkspaceEditConflict {
          retain = true
          try stampDraft(changed, stamp: stamp, baseline: baseline, at: file)
          conflict.buffer = file
          throw conflict
        } catch let error as WorkspaceError {
          guard !unchanged else { throw unchangedFailure(error, baseline: baseline) }
          rejected = (changed, error)
          let annotated =
            "# " + error.message.replacingOccurrences(of: "; ", with: "\n# ") + "\n" + text
          content = stamp == nil ? annotated : baseline.stamped(annotated)
        }
      }
    } catch let error as any CodedError {
      throw error
    } catch {
      throw WorkspaceError.editor
    }
  }

  private static func stampDraft(
    _ draft: String, stamp: Substring?, baseline: Baseline, at file: URL
  )
    throws
  {
    guard stamp == nil else { return }
    do {
      try baseline.stamped(draft).write(to: file, atomically: true, encoding: .utf8)
    } catch {
      let location = RestoreService.canNameInRecovery(file.path) ? " at " + file.path : ""
      throw CommandFailure(
        error: WorkspaceEditConflict(workspace: baseline.slug),
        next: [workspaceEditRead(baseline.slug)],
        message: "Workspace configuration changed while editing. Copy your edits from the private "
          + "draft kept\(location) onto a fresh workspace snapshot.")
    }
  }

  private static func unchangedFailure(_ error: WorkspaceError, baseline: Baseline)
    -> CommandFailure
  {
    CommandFailure(error: error, next: [workspaceEditRead(baseline.slug)], nextBy: .agent)
  }

  private static func save(
    _ config: WorkspaceConfig, baseline: Baseline, store: DatabaseStore,
    identity: (ids: any IDGenerator, date: Date), approval: (HumanApproval?, String)
  ) throws -> String {
    if let original = baseline.slug, config.slug != original {
      throw WorkspaceError.invalid(["line 1: workspace renaming is not supported"])
    }
    try store.write { tx in
      try baseline.check(in: tx.database)
      try config.apply(in: tx, ids: identity.ids, at: identity.date)
      try approval.0?.record(
        command: approval.1, workspace: config.slug, identity: identity, in: tx)
    }
    return config.slug
  }
}

/// A stale configuration requires reviewing the current state before another edit.
struct WorkspaceEditConflict: CodedError {
  let workspace: String?
  var buffer: URL?

  var code: ErrorCode { .conflict }
  var nextBy: NextBy { .agent }
  var next: [String] { [workspaceEditRead(workspace)] }

  var message: String {
    let change = "Workspace configuration changed while editing. Review the current configuration."
    guard let buffer else { return change }
    return RestoreService.canNameInRecovery(buffer.path)
      ? change + " The edited YAML is kept at \(buffer.path)."
      : change + " The edited YAML is kept in a private temporary file."
  }
}

private func workspaceEditRead(_ slug: String?) -> String {
  guard let slug, WorkspaceConfig.isValidIdentifier(slug),
    RestoreService.canNameInRecovery(slug)
  else { return "silta ws ls" }
  return workspaceCommand("silta ws show", workspace: slug)
}
