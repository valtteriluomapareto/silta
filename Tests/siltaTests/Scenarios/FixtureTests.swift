import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct FixtureTests {
  @Test func deterministicFixturesCoverHistoryAndCloneStates() throws {
    try withScratchDirectory { scratch in
      var identities: [String] = []
      for index in 0..<2 {
        let root = scratch.appending(path: "fixtures-\(index)")
        let script = ScenarioRunner.repository.appending(path: "scripts/make-fixtures.sh")
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/bash"), [script.path, root.path], in: scratch)
        try #require(result.termination == .exit(0), "\(result.stderr)")
        let repo = root.appending(path: "acme-platform")
        let refs = try git(["show-ref"], at: repo, scratch: scratch)
        identities.append(refs)
        for ref in [
          "master", "portal", "api", "portal-prod", "api-prod", "renamed", "from-non-app",
          "rebased",
        ] {
          #expect(refs.contains("refs/heads/" + ref))
        }
        #expect(!refs.contains("refs/heads/old-name"))
        try checkPromotionChain(repo, scratch: scratch)
        #expect(
          try git(
            ["rev-parse", "--is-shallow-repository"], at: root.appending(path: "acme-shallow"),
            scratch: scratch) == "true\n")
        #expect(
          try git(["remote"], at: root.appending(path: "acme-missing-remote"), scratch: scratch)
            == "")
        #expect(
          try git(
            ["branch", "--show-current"], at: root.appending(path: "acme-detached"),
            scratch: scratch) == "")
        #expect(
          try git(
            ["branch", "--show-current"], at: root.appending(path: "acme-portal-worktree"),
            scratch: scratch) == "portal\n")
        #expect(
          try git(["rev-parse", "rebased"], at: repo, scratch: scratch)
            != git(["rev-parse", "before-rebase"], at: repo, scratch: scratch))
        #expect(
          try git(["rev-parse", "rebased"], at: repo, scratch: scratch)
            == git(
              ["rev-parse", "refs/heads/rebased"], at: root.appending(path: "acme-origin.git"),
              scratch: scratch))
        #expect(
          FileManager.default.fileExists(
            atPath: repo.appending(path: "apps/console/README.md").path))
      }
      #expect(identities[0] == identities[1])
    }
  }

  /// Tests get a relocated copy of one template per process; it must behave like a fresh
  /// run of the script at its own path.
  @Test func copiedFixturesMatchAFreshRun() throws {
    try withScratchDirectory { scratch in
      let fresh = scratch.appending(path: "fresh")
      let made = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), [AcmeFixtures.script.path, fresh.path], in: scratch)
      try #require(made.termination == .exit(0), "\(made.stderr)")
      let copy = scratch.appending(path: "copy")
      let copied = try AcmeFixtures.make(at: copy)
      try #require(copied.termination == .exit(0), "\(copied.stderr)")
      let commands = [
        ["show-ref"], ["remote", "-v"], ["worktree", "list", "--porcelain"],
        ["status", "--porcelain", "--branch"], ["log", "-g", "--format=%gs", "HEAD"],
        ["config", "--local", "--list"], ["fsck", "--no-progress"],
      ]
      for repo in [
        "acme-platform", "acme-portal-worktree", "acme-detached", "acme-shallow",
        "acme-missing-remote",
      ] {
        for command in commands {
          let expected = try git(command, at: fresh.appending(path: repo), scratch: scratch)
          let actual = try git(command, at: copy.appending(path: repo), scratch: scratch)
          #expect(
            actual.replacing(copy.path, with: "<root>")
              == expected.replacing(fresh.path, with: "<root>"), "\(repo): git \(command)")
        }
      }
      #expect(
        try git(["show-ref"], at: copy.appending(path: "acme-origin.git"), scratch: scratch)
          == git(["show-ref"], at: fresh.appending(path: "acme-origin.git"), scratch: scratch))
      #expect(try files(in: copy) == files(in: fresh))
      let template = try #require(try AcmeFixtures.templatePath())
      for file in try files(in: copy).keys {
        let data = try Data(contentsOf: copy.appending(path: file))
        #expect(data.firstRange(of: Data(template.utf8)) == nil, "\(file) names the template")
      }
    }
  }

  @Test func scriptRefusesAnOccupiedDestination() throws {
    try withScratchDirectory { scratch in
      let destination = scratch.appending(path: "fixtures")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let sentinel = destination.appending(path: "Acme.txt")
      try Data("Acme".utf8).write(to: sentinel)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), [AcmeFixtures.script.path, destination.path], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stderr == "fixture destination must be empty\n")
      #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Acme.txt"])
      #expect(try AcmeFixtures.make(at: destination) == result)
    }
  }

  /// Permissions of every regular file under `root`, by relative path.
  private func files(in root: URL) throws -> [String: Int] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey]
    let enumerator = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)))
    var files: [String: Int] = [:]
    for case let file as URL in enumerator
    where try file.resourceValues(forKeys: keys).isRegularFile == true {
      let relative = String(file.path.dropFirst(root.path.count + 1))
      let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
      files[relative] = mode as? Int ?? -1
    }
    return files
  }

  @Test func occupiedFixtureDestinationIsPreservedAndRunnerReportsFailure() throws {
    try withScratchDirectory { scratch in
      let destination = scratch.appending(path: "fixtures")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let sentinel = destination.appending(path: "Acme.txt")
      try Data("Acme".utf8).write(to: sentinel)
      let file = scratch.appending(path: "fixture-failure.yaml")
      try Data("fixtures: true\nsteps: []\n".utf8).write(to: file)
      let evidence = scratch.appending(path: "evidence")
      #expect(throws: ScenarioFailure.self) {
        try ScenarioRunner.run(file, in: scratch, evidence: evidence)
      }
      #expect(try Data(contentsOf: sentinel) == Data("Acme".utf8))
      let failure = try String(contentsOf: evidence.appending(path: "failure.md"), encoding: .utf8)
      #expect(failure.contains("fixture"))
    }
  }

  private func checkPromotionChain(_ repo: URL, scratch: URL) throws {
    let portal = try git(["rev-parse", "portal"], at: repo, scratch: scratch)
    #expect(try git(["merge-base", "portal", "api"], at: repo, scratch: scratch) == portal)
    for (app, prod) in [("portal", "portal-prod"), ("api", "api-prod")] {
      #expect(
        try git(["rev-parse", app], at: repo, scratch: scratch)
          == git(["rev-parse", prod], at: repo, scratch: scratch))
    }
    #expect(
      try git(["merge-base", "api", "from-non-app"], at: repo, scratch: scratch)
        == git(["rev-parse", "master"], at: repo, scratch: scratch))
    #expect(
      try git(["merge-base", "non-app", "from-non-app"], at: repo, scratch: scratch)
        == git(["rev-parse", "non-app"], at: repo, scratch: scratch))
  }

  private func git(_ args: [String], at cwd: URL, scratch: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: cwd)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    return result.stdout
  }
}
