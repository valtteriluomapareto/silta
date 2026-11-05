/// What a restore did, or would do, to the workspace: enough for the human to approve it
/// knowingly from a dry run (spec §15).
package struct RestoreReport: Encodable, Equatable, Sendable {
  /// Row counts before and after.
  package struct Counts: Encodable, Equatable, Sendable {
    /// Before the restore.
    package var before: Int
    /// After the restore.
    package var after: Int

    /// The two counts.
    package init(before: Int, after: Int) {
      self.before = before
      self.after = after
    }
  }

  /// A setting whose stored JSON value differs; nil when the key is unset.
  package struct SettingChange: Encodable, Equatable, Sendable {
    /// The setting key.
    package var key: String
    /// The current value as JSON.
    package var before: String?
    /// The tree's value as JSON.
    package var after: String?

    /// One changed setting.
    package init(key: String, before: String?, after: String?) {
      self.key = key
      self.before = before
      self.after = after
    }
  }

  /// A live claim the restore replaces.
  package struct Claim: Encodable, Equatable, Sendable {
    /// The task ref as it is now.
    package var task: String
    /// The claiming actor.
    package var actor: String

    /// One replaced claim.
    package init(task: String, actor: String) {
      self.task = task
      self.actor = actor
    }
  }

  /// The workspace slug.
  package var workspace: String
  /// Whether the transaction was rolled back.
  package var dryRun: Bool
  /// Whether the workspace did not exist before.
  package var created: Bool
  /// Whether the replaced workspace has the tree's uid; true when created.
  package var sameUID: Bool
  /// The sha256 of the tree's `manifest.json`.
  package var manifestSHA256: String
  /// Tasks before and after.
  package var tasks: Counts
  /// Refs of tasks that exist now and not in the tree.
  package var removed: [String]
  /// Refs of tasks whose row or records differ from the tree.
  package var changed: [String]
  /// Settings whose values differ.
  package var settings: [SettingChange]
  /// Approval rows the tree adds.
  package var approvalsAdded: Int
  /// Claims that change or disappear.
  package var claimsReplaced: [Claim]
  /// Repo slugs left without a local path.
  package var reposWithoutPath: [String]
  /// The before-restore snapshot, for a real run.
  package var snapshot: String?

  enum CodingKeys: String, CodingKey {
    case workspace, created, tasks, removed, changed, settings, snapshot
    case dryRun = "dry_run"
    case sameUID = "same_uid"
    case manifestSHA256 = "manifest_sha256"
    case approvalsAdded = "approvals_added"
    case claimsReplaced = "claims_replaced"
    case reposWithoutPath = "repos_without_path"
  }
}
