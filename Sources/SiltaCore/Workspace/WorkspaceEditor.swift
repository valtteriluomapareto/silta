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

  /// Captures the configuration before evaluating the supplied YAML input.
  package static func apply(
    _ input: @autoclosure () throws -> String, slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date), approved: String? = nil,
    prepared: Result<String?, any Error>? = nil
  ) throws -> String? {
    let command = approvalCommand(slug) + " -F <file>"
    let approval = try actor.requireHuman(command: command, approved: approved)
    let captured = Result { try capture(slug: slug, store: store, prepared: prepared) }
    let text = try input()
    let baseline = try captured.get()
    let config = try WorkspaceConfig.parse(text)
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
          slug: nil, uid: nil, text: "workspace: {slug: acme, name: Acme, task_prefix: AC}\n")
      }
    }
    let selected = try WorkspaceSelection.resolve(slug, in: store, prepared: prepared)
    return try store.read { db in
      guard let uid = try uid(in: db, slug: selected) else {
        throw WorkspaceError.unknown(selected)
      }
      return Baseline(
        slug: selected, uid: uid, text: try WorkspaceConfig.render(from: db, slug: selected))
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
        let unchanged = changed.utf8.elementsEqual(content.utf8)
        if let rejected, unchanged || changed.utf8.elementsEqual(rejected.text.utf8) {
          throw unchangedFailure(rejected.error, baseline: baseline)
        }
        do {
          let config = try WorkspaceConfig.parse(changed)
          guard !unchanged else { return nil }
          return try save(
            config, baseline: baseline, store: store, identity: identity, approval: approval)
        } catch var conflict as WorkspaceEditConflict {
          retain = true
          conflict.buffer = file
          throw conflict
        } catch let error as WorkspaceError {
          guard !unchanged else { throw unchangedFailure(error, baseline: baseline) }
          rejected = (changed, error)
          content =
            "# " + error.message.replacingOccurrences(of: "; ", with: "\n# ") + "\n" + changed
        }
      }
    } catch let error as any CodedError {
      throw error
    } catch {
      throw WorkspaceError.editor
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
