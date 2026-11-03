/// Options for recording a completed task's commit.
package struct TaskCommit: Sendable {
  /// Overrides HEAD with a commit from the registered repository.
  package var sha: String?

  /// Skips git attribution for this completion.
  package var noSHA = false

  /// Lets a human override an unmet review gate.
  package var force = false

  /// Lets a human retain detected secret content in the result.
  package var allowSecret = false

  /// Uses HEAD and enforces the review gate by default.
  package init() {}

  /// The completion options with safe refs and no result text or file contents.
  package func command(_ ref: String, dropped: Bool) -> String {
    var value = (dropped ? "silta task drop " : "silta task done ") + shellWord(ref)
    if force { value += " --force" }
    if let sha { value += " --sha " + shellWord(sha) }
    if noSHA { value += " --no-sha" }
    return value
  }

}
