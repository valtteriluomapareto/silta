package import Foundation

/// Runs an approved editing loop over a temporary YAML view.
package enum WorkspaceEditor {
  /// Requires the human's go-ahead before reading configuration or invoking the editor.
  /// Returns nil on unchanged input or a nonzero editor exit, leaving storage untouched.
  package static func edit(
    slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date), approved: String? = nil,
    prepared: Result<String?, any Error>? = nil, editor: (URL) throws -> Int32
  ) throws -> String? {
    let target = slug.map { " " + shellWord($0) } ?? ""
    let approval = try actor.requireHuman(
      command: "silta ws edit" + target + " -F <file>", approved: approved)
    if slug == nil { _ = try prepared?.get() }
    let available = try WorkspaceSelection.list(in: store)
    let initial: String
    var originalSlug = slug
    if slug == nil && available.isEmpty {
      initial = "workspace: {slug: acme, name: Acme, task_prefix: AC}\n"
    } else {
      let selected = try WorkspaceSelection.resolve(slug, in: store, prepared: prepared)
      originalSlug = selected
      initial = try store.read { try WorkspaceConfig.render(from: $0, slug: selected) }
    }
    do {
      let directory = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: FileManager.default.temporaryDirectory, create: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      defer { try? FileManager.default.removeItem(at: directory) }  // best-effort temporary cleanup
      let file = directory.appending(path: "workspace.yaml")
      var content = initial
      while true {
        try content.write(to: file, atomically: true, encoding: .utf8)
        guard try editor(file) == 0 else { return nil }
        let changed = try String(contentsOf: file, encoding: .utf8)
        do {
          _ = try WorkspaceConfig.parse(changed)
          guard changed != content else { return nil }
          return try save(
            changed, originalSlug: originalSlug, store: store, identity: identity,
            approval: (approval, "silta ws edit" + target))
        } catch let error as WorkspaceError {
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

  /// Applies a UTF-8 YAML document with the same validation and write as an editor save.
  package static func apply(
    _ text: String, slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date), approved: String? = nil,
    prepared: Result<String?, any Error>? = nil
  ) throws -> String? {
    let target = slug.map { " " + shellWord($0) } ?? ""
    let approval = try actor.requireHuman(
      command: "silta ws edit" + target + " -F <file>", approved: approved)
    if slug == nil { _ = try prepared?.get() }
    let available = try WorkspaceSelection.list(in: store)
    let original =
      try slug == nil && available.isEmpty
      ? nil : WorkspaceSelection.resolve(slug, in: store, prepared: prepared)
    _ = try WorkspaceConfig.parse(text)
    if let original,
      try store.read({ try WorkspaceConfig.render(from: $0, slug: original) }) == text
    {
      return nil
    }
    return try save(
      text, originalSlug: original, store: store, identity: identity,
      approval: (approval, "silta ws edit" + target + " -F <file>"))
  }

  private static func save(
    _ text: String, originalSlug: String?, store: DatabaseStore,
    identity: (ids: any IDGenerator, date: Date), approval: (HumanApproval?, String)
  ) throws -> String {
    let config = try WorkspaceConfig.parse(text)
    if let originalSlug, config.slug != originalSlug {
      throw WorkspaceError.invalid(["line 1: workspace renaming is not supported"])
    }
    try store.write { tx in
      try config.apply(in: tx, ids: identity.ids, at: identity.date)
      try approval.0?.record(
        command: approval.1, workspace: config.slug, identity: identity, in: tx)
    }
    return config.slug
  }

}
