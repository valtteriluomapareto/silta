import Foundation

/// Immutable commit evidence and the configuration it describes, prepared before a write.
struct DocVerification: Sendable {
  struct Snapshot: Codable, Equatable, Sendable {
    let app: String
    let ref: String
    let sha: String
    let uid: String?

    init(app: String, ref: String, sha: String, uid: String? = nil) {
      self.app = app
      self.ref = ref
      self.sha = sha
      self.uid = uid
    }
  }

  struct TargetBinding: Equatable, Sendable {
    let kind: String
    let uid: String
    let serviceUID: String?
  }

  struct AppBinding: Equatable, Sendable {
    let app: String
    let uid: String
    let ref: String
    let repo: String
    let repoUID: String
    let path: String?
    let subpath: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
      DocVerification.legacyNameEqual(lhs.app, rhs.app) && lhs.uid == rhs.uid
        && Data(lhs.ref.utf8) == Data(rhs.ref.utf8)
        && DocVerification.legacyNameEqual(lhs.repo, rhs.repo) && lhs.repoUID == rhs.repoUID
        && lhs.path.map({ Data($0.utf8) }) == rhs.path.map({ Data($0.utf8) })
        && lhs.subpath.map({ Data($0.utf8) }) == rhs.subpath.map({ Data($0.utf8) })
    }
  }

  struct Binding: Equatable, Sendable {
    let workspace: String
    let workspaceUID: String
    let title: String
    let kind: String
    let about: [String]
    let targets: [TargetBinding]
    let apps: [AppBinding]

    static func == (lhs: Self, rhs: Self) -> Bool {
      DocVerification.legacyNameEqual(lhs.workspace, rhs.workspace)
        && lhs.workspaceUID == rhs.workspaceUID
        && Data(lhs.title.utf8) == Data(rhs.title.utf8)
        && Data(lhs.kind.utf8) == Data(rhs.kind.utf8)
        && lhs.about == rhs.about && lhs.targets == rhs.targets && lhs.apps == rhs.apps
    }
  }

  let binding: Binding
  let snapshots: [Snapshot]

  static func prepare(_ draft: DocDraft, workspace: Int64, environment: SiltaEnvironment)
    async throws -> Self
  {
    let binding = try readBinding(draft, workspace: workspace, store: environment.db)
    return try await prepare(binding, environment: environment)
  }

  static func prepare(_ binding: Binding, environment: SiltaEnvironment) async throws -> Self {
    let code = CodeService(
      workspace: binding.workspace, store: environment.db, git: environment.git,
      at: environment.clock.now())
    var snapshots: [Snapshot] = []
    for app in binding.apps {
      guard let path = app.path else { continue }
      do {
        let sha = try await code.resolveCommit(
          app: app.app, ref: app.ref, repo: app.repo, path: path)
        snapshots.append(Snapshot(app: app.app, ref: app.ref, sha: sha, uid: app.uid))
      } catch let error as CodeError {
        guard !Task.isCancelled else { throw error }
        switch error {
        case .notFound, .git, .timeout: continue
        case .invalid, .fetch: throw error
        }
      } catch let error as RepoError {
        guard case .localPath = error, !Task.isCancelled else { throw error }
      }
    }
    return Self(binding: binding, snapshots: snapshots)
  }

  func matches(_ current: Binding) -> Bool {
    guard binding == current,
      snapshots.allSatisfy({ [40, 64].contains($0.sha.count) && $0.sha.allSatisfy(\.isHexDigit) })
    else { return false }
    var index = 0
    for app in current.apps {
      guard index < snapshots.count else { break }
      let snapshot = snapshots[index]
      if Self.legacyNameEqual(snapshot.app, app.app)
        && Data(snapshot.ref.utf8) == Data(app.ref.utf8)
        && (snapshot.uid.map { StoredUID.valid(Data($0.utf8)) && $0 == app.uid } ?? true)
      {
        index += 1
      }
    }
    return index == snapshots.count
  }

  private static func legacyNameEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
  }

  func encodedSnapshots() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let json = String(data: try encoder.encode(snapshots), encoding: .utf8) else {
      throw StorageError.internalMisuse
    }
    return json
  }
}
