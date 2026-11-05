import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// One name a scan refuses, and what the refusal must show and suggest.
struct InvalidName {
  let slug: String?

  let prefix: String?

  let directory: String

  let flag: String

  let shown: String

  /// Whether the refusal comes before discovery runs.
  let early: Bool
}

@Suite(.timeLimit(.minutes(1)))
struct ScanNamingTests {
  /// A scan that may name a new workspace, through the API the command uses.
  static func create(
    _ roots: [URL], slug: String? = nil, prefix: String? = nil, store: DatabaseStore,
    git: any GitRunner, seed: UInt64 = 1
  ) async throws -> ScanOutcome {
    let target: ScanTarget =
      if slug == nil, prefix == nil { .derived } else { .named(slug: slug, prefix: prefix) }
    return try await RepositoryScan.scan(
      roots, target: target, store: store, git: git,
      identity: (SeededIDGenerator(seed: seed), WorkspaceConfigTests.instant))
  }

  /// Makes `url` a clone and returns its canonical path.
  static func clone(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.appending(path: ".git"), withIntermediateDirectories: true)
    return try RepositoryScanTests.path(url)
  }

  /// Every workspace as `slug:name:prefix`, ordered by slug.
  static func workspaces(_ store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try Row.fetchAll(db, sql: "SELECT slug,name,task_prefix FROM workspace ORDER BY slug").map {
        "\($0["slug"] as String):\($0["name"] as String):\($0["task_prefix"] as String)"
      }
    }
  }

  /// The coded refusal `body` raises, or nil after recording an issue.
  static func refusal(
    _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
  ) async -> (any CodedError)? {
    do {
      try await body()
      Issue.record("Expected a refusal", sourceLocation: sourceLocation)
      return nil
    } catch let error as any CodedError {
      return error
    } catch {
      Issue.record("Uncoded error: \(error)", sourceLocation: sourceLocation)
      return nil
    }
  }

  @Test func chosenSlugAndPrefixNameANewWorkspace() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      let path = try Self.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await Self.create(
        [repo], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(outcome.workspace == "work")
      #expect(try Self.workspaces(store) == ["work:work:WK"])
    }
  }

  @Test func chosenSlugAloneDerivesThePrefixFromTheSlug() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      let path = try Self.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await Self.create(
        [repo], slug: "work", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(try Self.workspaces(store) == ["work:work:WO"])
    }
  }

  @Test func prefixWithoutSlugKeepsTheDirectoryName() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      let path = try Self.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await Self.create(
        [repo], prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(try Self.workspaces(store) == ["acme:acme:WK"])
    }
  }

  @Test func defaultNamingComesFromTheFirstDirectory() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "Acme")
      let path = try Self.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await Self.create(
        [repo], store: store, git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(try Self.workspaces(store) == ["acme:Acme:AC"])
    }
  }

  @Test func aSingleLetterDirectoryGetsASingleLetterPrefix() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "x")
      let path = try Self.clone(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await Self.create(
        [repo], store: store, git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(try Self.workspaces(store) == ["x:x:X"])
    }
  }

  @Test func chosenSlugOfAnExistingWorkspaceIsRefusedWithoutChanges() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let before = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
      let repo = home.appending(path: "new")
      let path = try Self.clone(repo)
      let error = await Self.refusal {
        _ = try await Self.create(
          [repo], slug: "acme", store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("acme") == true)
      #expect(try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") } == before)
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }

  @Test func slugAndPrefixClashesCompareCaseInsensitively() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      for (slug, prefix) in [("ACME", "QQ"), ("Acme", "ZZ")] {
        let repo = home.appending(path: "new-\(slug)")
        let path = try Self.clone(repo)
        let error = await Self.refusal {
          _ = try await Self.create(
            [repo], slug: slug, prefix: prefix, store: store,
            git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
        }
        #expect(error?.code == .conflict)
        #expect(error?.message.contains("acme") == true)
      }
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }

  @Test func derivedPrefixClashNamesTheHolderAndTheFix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let repo = home.appending(path: "acorn")
      let path = try Self.clone(repo)
      let error = await Self.refusal {
        _ = try await Self.create(
          [repo], store: store, git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("acme") == true)
      #expect(error?.message.contains("derived") == true)
      #expect(error?.next.first?.contains("--prefix") == true)
      #expect(error?.next.first?.contains(repo.path) == true)
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }

  @Test func chosenPrefixClashNamesTheHolderAndTheFix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let repo = home.appending(path: "work")
      let path = try Self.clone(repo)
      let error = await Self.refusal {
        _ = try await Self.create(
          [repo], prefix: "ac", store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("acme") == true)
      #expect(error?.next.first?.contains("--prefix") == true)
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }

  @Test func slugExistsOffersAnotherSlugThenTheRescan() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let api = home.appending(path: "api")
      let web = home.appending(path: "web")
      let directories = [api, web]
      var script: [(GitRequest, Result<GitResult, any Error>)] = []
      for directory in directories {
        script += RepositoryScanTests.script(try Self.clone(directory))
      }
      let error = await Self.refusal {
        _ = try await Self.create(
          directories, slug: "acme", store: store, git: ScriptedGitRunner(script: script))
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("already registered") == true)
      #expect(error?.next.count == 2)
      #expect(error?.next.first?.contains("--slug <another-slug>") == true)
      #expect(error?.next.last?.hasSuffix("--ws 'acme'") == true)
      for next in error?.next ?? []
      where next.contains("<another-slug>") == false {
        #expect(next.contains(api.path) && next.contains(web.path))
      }
    }
  }

  /// A scan without naming options refreshes an existing workspace, whatever its
  /// directory would derive: `a-team` derives the invalid prefix `A-`.
  @Test func noOptionScanOfAnExistingWorkspaceKeepsItsStoredPrefix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(
        "workspace: {slug: a-team, name: A Team, task_prefix: AT}\nrepos: [{slug: team}]\n",
        to: store)
      let root = home.appending(path: "a-team")
      let path = try Self.clone(root.appending(path: "team"))
      let outcome = try await Self.create(
        [root], store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(outcome.workspace == "a-team")
      #expect(try Self.workspaces(store) == ["a-team:A Team:AT"])
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT path FROM repo_path") } == path.path)
    }
  }

  @Test func invalidNamesFailAndNameTheFix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let cases = [
        InvalidName(
          slug: "My Projects", prefix: nil, directory: "acme", flag: "--slug",
          shown: "My Projects", early: true),
        InvalidName(
          slug: nil, prefix: "A_", directory: "acme", flag: "--prefix", shown: "A_",
          early: true),
        InvalidName(
          slug: nil, prefix: nil, directory: "My Projects", flag: "--slug",
          shown: "My Projects", early: true),
        InvalidName(
          slug: nil, prefix: nil, directory: ".hidden", flag: "--slug",
          shown: ".hidden", early: true),
        InvalidName(
          slug: nil, prefix: nil, directory: "a_b", flag: "--prefix", shown: "a_b",
          early: false),
      ]
      for testCase in cases {
        let root = home.appending(path: testCase.directory)
        let clone = try Self.clone(root.appending(path: "clone"))
        let git =
          testCase.early
          ? ScriptedGitRunner(script: [])
          : ScriptedGitRunner(script: RepositoryScanTests.script(clone))
        let error = await Self.refusal {
          _ = try await Self.create(
            [root], slug: testCase.slug, prefix: testCase.prefix, store: store, git: git)
        }
        #expect(error?.code == .invalid)
        #expect(error?.message.contains("letters, digits, _ or -") == true)
        #expect(error?.message.contains(testCase.shown) == true)
        let placeholder = "<" + testCase.flag.dropFirst(2) + ">"
        #expect(
          error?.next == [
            "silta init --scan \(shellWord(root.path)) \(testCase.flag) \(placeholder)"
          ])
        if testCase.early { #expect(git.requests.isEmpty) }
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

}

extension ScanNamingTests {
  @Test func aRepoPathHeldByAnotherWorkspaceNamesTheFix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: api}]", to: store)
      let root = home.appending(path: "projects")
      let path = try Self.clone(root.appending(path: "api"))
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [path.path])
      }
      let error = await Self.refusal {
        _ = try await Self.create(
          [root], slug: "other", store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(path)), seed: 2)
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("api") == true)
      #expect(error?.message.contains("acme") == true)
      #expect(error?.next == ["silta --ws 'acme' init --scan \(shellWord(path.path))"])
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }

}

extension ScanNamingTests {
  /// A prefix derived from `--slug` names the slug as its source, not the directory.
  @Test func aPrefixDerivedFromAChosenSlugNamesTheSlug() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let root = home.appending(path: "zed")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let error = await Self.refusal {
        _ = try await Self.create(
          [root], slug: "x-y", store: store, git: ScriptedGitRunner(script: []))
      }
      #expect(error?.code == .invalid)
      #expect(
        error?.message.contains("Slug \"x-y\" gives the invalid task prefix \"X-\"") == true)
      #expect(error?.message.contains("Directory name") == false)
      #expect(
        error?.next == [
          "silta init --scan \(shellWord(root.path)) --slug x-y --prefix <prefix>"
        ])
    }
  }

  /// A no-option scan finds a workspace whose stored spelling differs in case, and
  /// keeps that spelling.
  @Test func aNoOptionRescanFindsAWorkspaceSpelledDifferently() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let repo = home.appending(path: "acme")
      let path = try Self.clone(repo)
      _ = try await Self.create(
        [repo], slug: "ACME", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      let again = try await Self.create(
        [repo], store: store, git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      #expect(again.workspace == "ACME")
      #expect(try Self.workspaces(store) == ["ACME:ACME:AC"])
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT path FROM repo_path") } == path.path)
    }
  }

  /// `--prefix` alone cannot name an existing workspace: the refusal says the
  /// option is for a new workspace and puts the rescan first.
  @Test func prefixOnlyOnAnExistingWorkspaceSaysItAppliesToANewOne() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      let root = home.appending(path: "acme")
      let path = try Self.clone(root)
      let error = await Self.refusal {
        _ = try await Self.create(
          [root], prefix: "WK", store: store,
          git: ScriptedGitRunner(script: RepositoryScanTests.script(path)))
      }
      #expect(error?.code == .conflict)
      #expect(error?.message.contains("--prefix applies only to a new workspace") == true)
      #expect(error?.next.first?.hasSuffix("--ws 'acme'") == true)
      #expect(error?.next.count == 2)
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
    }
  }
}

extension ScanNamingTests {
  /// A clone directory that is no identifier still scans: its repo slug is the
  /// directory name normalized, and nothing on disk is renamed.
  @Test func aRepoDirectoryNameIsNormalizedIntoASlug() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "My Projects")
      let path = try Self.clone(root)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await Self.create(
        [root], slug: "work", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path, listed: root)))
      #expect(outcome.workspace == "work")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT slug FROM repo") } == "my-projects")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT path FROM repo_path") } == path.path)
      #expect(FileManager.default.fileExists(atPath: root.appending(path: ".git").path))
    }
  }

  /// Two directories that normalize to one slug keep the duplicate-slug refusal.
  @Test func reposThatNormalizeToTheSameSlugAreRefused() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let first = root.appending(path: "a/My Projects")
      let second = root.appending(path: "b/my projects")
      var script = RepositoryScanTests.script(try Self.clone(first), listed: first)
      script += RepositoryScanTests.script(try Self.clone(second), listed: second)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.duplicateSlug) {
        _ = try await Self.create(
          [root], slug: "work", store: store, git: ScriptedGitRunner(script: script))
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  /// A valid clone reached through a worktree or alias with an unusual name still
  /// scans into the canonical main clone.
  @Test(arguments: ["My Worktree", "My Alias"])
  func anUnusualWorktreeOrAliasNameStillScans(_ name: String) async throws {
    try await withScratchDirectory { home in
      let main = home.appending(path: "acme")
      let mainPath = try Self.clone(main)
      let root = home.appending(path: name)
      let script: [(GitRequest, Result<GitResult, any Error>)]
      if name == "My Alias" {
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: main)
        script = RepositoryScanTests.script(mainPath)
      } else {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".git"))
        script = RepositoryScanTests.script(try RepositoryScanTests.path(root), main: mainPath)
      }
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await Self.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: script))
      #expect(outcome.workspace == "work")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT slug FROM repo") } == "acme")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT path FROM repo_path") }
          == mainPath.path)
    }
  }
}

extension ScanNamingTests {
  /// Every repo and the path bound to it, ordered by slug.
  static func repoPaths(_ store: DatabaseStore) throws -> [(slug: String, path: String)] {
    try store.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT repo.slug AS slug,repo_path.path AS path
          FROM repo
          LEFT JOIN repo_path ON repo_path.repo_id=repo.id
          ORDER BY repo.slug
          """
      ).map { (slug: $0["slug"] as String, path: $0["path"] as String? ?? "") }
    }
  }

  /// Two directories that both normalize to the reserved `none` are a duplicate
  /// before any remapping can give them different names.
  @Test func reservedSlugsThatNormalizeAlikeAreRefused() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "scan")
      let none = root.appending(path: "none")
      let hidden = root.appending(path: ".none")
      var script: [(GitRequest, Result<GitResult, any Error>)] = []
      for directory in [none, hidden].sorted(by: { $0.path < $1.path }) {
        script += RepositoryScanTests.script(try Self.clone(directory), listed: directory)
      }
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.duplicateSlug) {
        _ = try await Self.create(
          [root], slug: "work", prefix: "WK", store: store,
          git: ScriptedGitRunner(script: script))
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  /// A directory that is only punctuation, or only a dot, still becomes a repo slug.
  @Test(arguments: [(".hidden", "hidden"), ("___", "repo")])
  func boundaryDirectoryNamesNormalizeIntoASlug(_ name: String, _ slug: String) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "work")
      let clone = root.appending(path: name)
      let path = try Self.clone(clone)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await Self.create(
        [root], slug: "work", prefix: "WK", store: store,
        git: ScriptedGitRunner(script: RepositoryScanTests.script(path, listed: clone)))
      #expect(outcome.workspace == "work")
      let stored = try Self.repoPaths(store)
      #expect(stored.map(\.slug) == [slug])
      #expect(stored.map(\.path) == [path.path])
      #expect(FileManager.default.fileExists(atPath: clone.appending(path: ".git").path))
    }
  }

  /// A refusal for the invalid slug keeps the supplied prefix, quoted, so the caller's
  /// other option is neither dropped nor run as shell words. A value starting with `-`
  /// joins its option with `=`, so the parser reads it as the value it refused.
  @Test func anInvalidSlugKeepsTheSuppliedPrefix() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let chosen = home.appending(path: "acme")
      let derived = home.appending(path: "My Projects")
      let dashed = home.appending(path: "other")
      let cases = [
        (chosen, "Work Space", "!", "--prefix '!'"),
        (derived, nil, "!", "--prefix '!'"),
        (dashed, "Work Space", "-x", "--prefix='-x'"),
      ]
      for (root, slug, prefix, carried) in cases {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let error = await Self.refusal {
          _ = try await Self.create(
            [root], slug: slug, prefix: prefix, store: store, git: ScriptedGitRunner(script: []))
        }
        #expect(error?.code == .invalid)
        #expect(
          error?.next == [
            "silta init --scan \(shellWord(root.path)) --slug <slug> \(carried)"
          ])
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }
}
