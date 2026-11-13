import Foundation

/// Immutable commit evidence and the configuration it describes, prepared before a write.
struct DocVerification: Sendable {
  struct Snapshot: Codable, Equatable, Sendable {
    let app: String
    let ref: String
    let sha: String
  }

  struct TargetBinding: Equatable, Sendable {
    let kind: String
    let uid: String
    let serviceUID: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
      DocVerification.same(lhs.kind, rhs.kind) && DocVerification.same(lhs.uid, rhs.uid)
        && DocVerification.same(lhs.serviceUID, rhs.serviceUID)
    }
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
      DocVerification.same(lhs.app, rhs.app) && DocVerification.same(lhs.uid, rhs.uid)
        && DocVerification.same(lhs.ref, rhs.ref)
        && DocVerification.same(lhs.repo, rhs.repo)
        && DocVerification.same(lhs.repoUID, rhs.repoUID)
        && DocVerification.same(lhs.path, rhs.path)
        && DocVerification.same(lhs.subpath, rhs.subpath)
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
      DocVerification.same(lhs.workspace, rhs.workspace)
        && DocVerification.same(lhs.workspaceUID, rhs.workspaceUID)
        && DocVerification.same(lhs.title, rhs.title) && DocVerification.same(lhs.kind, rhs.kind)
        && lhs.about.elementsEqual(rhs.about, by: { DocVerification.same($0, $1) })
        && lhs.targets == rhs.targets && lhs.apps == rhs.apps
    }
  }

  let binding: Binding
  let snapshots: [Snapshot]

  static func prepare(_ draft: DocDraft, workspace: Int64, environment: SiltaEnvironment)
    async throws -> Self
  {
    let binding = try readBinding(draft, workspace: workspace, store: environment.db)
    let code = CodeService(
      workspace: binding.workspace, store: environment.db, git: environment.git,
      at: environment.clock.now())
    var snapshots: [Snapshot] = []
    for app in binding.apps {
      guard let path = app.path else {
        throw RepoError.localPath(repo: app.repo, workspace: binding.workspace)
      }
      let sha = try await code.resolveCommit(app: app.app, ref: app.ref, repo: app.repo, path: path)
      snapshots.append(Snapshot(app: app.app, ref: app.ref, sha: sha))
    }
    return Self(binding: binding, snapshots: snapshots)
  }

  func matches(_ current: Binding) -> Bool {
    binding == current && snapshots.count == current.apps.count
      && zip(snapshots, current.apps).allSatisfy {
        DocVerification.same($0.app, $1.app) && DocVerification.same($0.ref, $1.ref)
      }
      && snapshots.allSatisfy {
        [40, 64].contains($0.sha.count) && $0.sha.allSatisfy(\.isHexDigit)
      }
  }

  private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case (let left?, let right?): left.utf8.elementsEqual(right.utf8)
    default: false
    }
  }

  func encodedSnapshots() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(snapshots), as: UTF8.self)
  }
}
