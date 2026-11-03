package import Foundation

/// Runs the human editing loop over a temporary YAML view.
package enum WorkspaceEditor {
  /// Requires a human before reading configuration or invoking the supplied editor.
  /// Returns nil on unchanged input or a nonzero editor exit, leaving storage untouched.
  package static func edit(
    slug: String?, store: DatabaseStore, actor: ActorID,
    identity: (ids: any IDGenerator, date: Date),
    editor: (URL) throws -> Int32
  ) throws -> String? {
    let (ids, date) = identity
    try actor.requireHuman(command: "silta ws edit")
    let available = try WorkspaceSelection.list(in: store)
    let initial: String
    var originalSlug = slug
    if slug == nil && available.isEmpty {
      initial = "workspace: {slug: acme, name: Acme, task_prefix: AC}\n"
    } else {
      let selected = try WorkspaceSelection.resolve(slug, in: store)
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
        guard changed != content else { return nil }
        do {
          let config = try WorkspaceConfig.parse(changed)
          if let originalSlug, config.slug != originalSlug {
            throw WorkspaceError.invalid(["line 1: workspace renaming is not supported"])
          }
          try store.write { try config.apply(in: $0, ids: ids, at: date) }
          return config.slug
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
}
