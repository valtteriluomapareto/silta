import CryptoKit
import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct ControlPlaneTests {
  @Test(arguments: [["--version"], ["--help"], ["schema", "--json"], ["schema", "--nope"]])
  func everyCommandLogsOnce(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        arguments, in: scratch,
        environment: [
          "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "0",
        ])
      #expect(result.termination == .exit(arguments.contains("--nope") ? 1 : 0))
      let data = try Data(contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      #expect(
        (try #require(String(bytes: data, encoding: .utf8))).split(separator: "\n").count == 1)
      let entry = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(entry["timestamp"] as? String == "2023-11-14T22:13:20.000Z")
      #expect(entry["exit_code"] as? Int == (arguments.contains("--nope") ? 1 : 0))
      #expect(entry["error_code"] as? String == (arguments.contains("--nope") ? "usage" : nil))
    }
  }

  // Outside git the session is the working directory's hash (§11).
  @Test func sessionHashesTheWorkingDirectory() throws {
    try withScratchDirectory { scratch in
      let cwd = scratch.appending(path: "acme")
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
      let result = try SiltaBinary.run(
        ["--version"], in: scratch, cwd: cwd,
        environment: ["SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      #expect(result.termination == .exit(0))
      let data = try Data(contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let entry = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let hash = SHA256.hash(data: Data(cwd.path.utf8)).prefix(3)
        .map { String(format: "%02x", $0) }.joined()
      #expect(entry["actor"] as? String == "agent:unknown:" + hash)
    }
  }

  // Environment warnings reach the output and the log like a command's own. A git
  // fault (here an unknown repository format) is one; an agent's shell inheriting a
  // human's SILTA_ACTOR export is not.
  @Test func gitFaultWarnsAndAnInheritedHumanOverrideDoesNot() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "acme")
      let setup = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/git"), ["init", "-q", repo.path], in: scratch)
      try #require(setup.termination == .exit(0))
      try Data("[core]\n\trepositoryformatversion = 99\n".utf8)
        .write(to: repo.appending(path: ".git/config"))
      let result = try SiltaBinary.run(
        ["schema"], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "human:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      #expect(result.termination == .exit(0))
      #expect(result.stderr.contains("[session_fallback]"))
      #expect(!result.stderr.contains("actor_override_ignored"))
      let data = try Data(contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let entry = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(entry["warnings"] as? [String] == ["session_fallback"])
    }
  }

  // A working directory deleted under the shell must not crash git spawning.
  @Test func deletedWorkingDirectoryFallsBackInsteadOfCrashing() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "mkdir gone && cd gone && rmdir ../gone && exec \"$0\" schema",
          try SiltaBinary.url().path,
        ],
        in: scratch)
      #expect(result.termination == .exit(0), "\(result.stderr)")
      #expect(result.stderr.contains("[session_fallback]"))
    }
  }

  @Test func verboseKeepsJSONOnStdoutAndMirrorsOnlyDiagnostics() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(
        ["schema", "--json", "--verbose"], in: scratch,
        environment: ["SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      #expect(result.termination == .exit(0))
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      #expect(envelope["ok"] as? Bool == true)
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      #expect(result.stderr == log)
    }
  }

  @Test(arguments: [["schema", "--acme-private=value"], ["schema", "--", "Acme private body"]])
  func logsExcludeArgumentValuesAndUnknownFlags(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      _ = try SiltaBinary.run(
        arguments, in: scratch, environment: ["SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      #expect(!log.contains("private"))
      #expect(!log.contains("value"))
      #expect(!log.contains("body"))
    }
  }

  @Test func deterministicFlagReachesEnvironmentAndInvalidOverridesAreCoded() throws {
    try withScratchDirectory { scratch in
      // A home outside every temporary root: the package's .build, unless the checkout
      // is itself in /tmp, then the user's caches (which a sandbox may not let us write).
      let name = "silta-test-home-\(UUID().uuidString)"
      let build = DogfoodReportTests.root.appending(path: ".build/\(name)")
      let caches = try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
      ).appending(path: name)
      let usable = try [build, caches].first { candidate in
        try !SiltaHome.resolve(environment: ["SILTA_HOME": candidate.path]).permitsDeterminism
          && (try? FileManager.default.createDirectory(  // unwritable: try the next one
            at: candidate, withIntermediateDirectories: true)) != nil
      }
      let home = try #require(usable)
      defer { try? FileManager.default.removeItem(at: home) }  // test scratch cleanup
      let environment = ["SILTA_NOW": "bad", "SILTA_HOME": home.path]
      let disabled = try SiltaBinary.run(
        ["schema", "--json"], in: scratch, environment: environment)
      try #require(!SiltaHome.resolve(environment: environment).permitsDeterminism)
      #expect(disabled.termination == .exit(0))
      let result = try SiltaBinary.run(
        ["schema", "--json", "--deterministic"], in: scratch,
        environment: environment)
      #expect(result.termination == .exit(9))
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      #expect(error["code"] as? String == "env")
      #expect(error["next_by"] as? String == "human")
      #expect(result.stderr.isEmpty)
    }
  }
}
