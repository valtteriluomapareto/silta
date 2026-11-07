import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)))
struct DogfoodInstallTests {
  static func git(_ args: [String], in scratch: URL, cwd: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args,
      in: scratch, cwd: cwd)
    #expect(result.termination == .exit(0))
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func clone(_ scratch: URL) throws -> URL {
    let origin = scratch.appending(path: "origin")
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    _ = try git(["init", "-q", "-b", "main"], in: scratch, cwd: origin)
    let scripts = origin.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: DogfoodReportTests.root.appending(path: "scripts/install-dev.sh"),
      to: scripts.appending(path: "install-dev.sh"))
    try Data(".build/\n".utf8).write(to: origin.appending(path: ".gitignore"))
    _ = try git(["add", "."], in: scratch, cwd: origin)
    _ = try git(
      [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
        "Acme installer",
      ], in: scratch, cwd: origin)
    let clone = scratch.appending(path: "clone")
    _ = try git(["clone", "-q", origin.path, clone.path], in: scratch, cwd: scratch)
    return clone
  }

  static func install(_ clone: URL, scratch: URL, tools: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [clone.appending(path: "scripts/install-dev.sh").path], in: scratch,
      environment: [
        "PATH": tools.path + ":/usr/bin:/bin",
        "SILTA_INSTALL_DIR": scratch.appending(path: "installed").path,
      ])
  }

  @Test func installerRefusesDirtyOtherBranchAndDetachedBeforeBuild() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try DogfoodReportTests.tool(
        "swift",
        text: "#!/bin/bash\necho called >> "
          + shellWord(scratch.appending(path: "build-called").path) + "\nexit 99\n", in: tools)
      try Data("Acme untracked".utf8).write(to: clone.appending(path: "untracked"))
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      try FileManager.default.removeItem(at: clone.appending(path: "untracked"))
      _ = try Self.git(["checkout", "-qb", "codex/acme"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      _ = try Self.git(["checkout", "--detach", "-q"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "build-called").path))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "installed/silta").path))
    }
  }

  @Test(arguments: ["behind", "ahead"])
  func installerRefusesMainThatDiffersFromOrigin(direction: String) throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try DogfoodReportTests.tool(
        "swift", text: "#!/bin/bash\nmkdir -p .build/release\necho Acme > .build/release/silta\n",
        in: tools)
      let commit = [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit",
        "--allow-empty", "-qm", "Acme " + direction,
      ]
      let repository = direction == "behind" ? scratch.appending(path: "origin") : clone
      _ = try Self.git(commit, in: scratch, cwd: repository)
      let result = try Self.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(1))
      #expect(result.stderr.contains(direction == "behind" ? "1 behind" : "1 ahead"))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "installed/silta").path))
    }
  }

  @Test func installerBuildsCleanMainAndPreservesExistingBinaryOnFailure() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      let destination = scratch.appending(path: "installed/silta")
      try DogfoodReportTests.tool(
        "swift",
        text: """
          #!/bin/bash
          [[ "$*" == 'build -c release --only-use-versions-from-resolved-file' ]] || exit 98
          mkdir -p .build/release
          printf 'Acme binary' > .build/release/silta
          """, in: tools)
      let result = try Self.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
      let commit = try Self.git(["rev-parse", "HEAD"], in: scratch, cwd: clone)
      #expect(result.stdout.contains(commit))
      #expect(result.stdout.contains("Next: follow "))
      #expect(result.stdout.contains("/docs/getting-started.md.\n"))
      try DogfoodReportTests.tool("swift", text: "#!/bin/bash\nexit 42\n", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
      try FileManager.default.removeItem(at: clone.appending(path: ".build"))
      try DogfoodReportTests.tool("swift", text: "#!/bin/bash\nexit 0\n", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
    }
  }

  @Test func defaultInstallDirectoryUsesOnlyTheTemporaryHome() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try DogfoodReportTests.tool(
        "swift", text: "#!/bin/bash\nmkdir -p .build/release\necho Acme > .build/release/silta\n",
        in: tools)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [clone.appending(path: "scripts/install-dev.sh").path], in: scratch,
        environment: ["PATH": tools.path + ":/usr/bin:/bin"])
      #expect(result.termination == .exit(0))
      #expect(
        FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/.local/bin/silta").path))
    }
  }
}
