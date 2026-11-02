import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
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
      let git = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/git"),
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: scratch,
        cwd: ScenarioRunner.repository)
      try #require(git.termination == .exit(0))
      let checkout = URL(filePath: git.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        .deletingLastPathComponent()
      let home = checkout.appending(path: ".build/isolated-home-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: home) }  // test scratch cleanup
      let environment = ["SILTA_NOW": "bad", "SILTA_HOME": home.path]
      let disabled = try SiltaBinary.run(
        ["schema", "--json"], in: scratch, environment: environment)
      let automatic = try SiltaHome.resolve(environment: environment).permitsDeterminism
      #expect(disabled.termination == .exit(automatic ? 1 : 0))
      let result = try SiltaBinary.run(
        ["schema", "--json", "--deterministic"], in: scratch,
        environment: environment)
      #expect(result.termination == .exit(1))
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      #expect(error["code"] as? String == "invalid")
      #expect(result.stderr.isEmpty)
    }
  }
}
