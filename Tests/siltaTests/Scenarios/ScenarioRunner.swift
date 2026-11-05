import CryptoKit
import Foundation
import SiltaTestSupport
import Yams

/// Runs the repository-owned YAML contract against the built executable.
enum ScenarioRunner {
  static let repository = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let base = Date(timeIntervalSince1970: 1_700_000_000)

  static func environment(step: Int, overrides: [String: String], scratch: URL) -> [String: String]
  {
    overrides.merging([
      "HOME": scratch.appending(path: "home").path,
      "SILTA_HOME": scratch.appending(path: "silta-home").path,
      "SILTA_NOW": base.addingTimeInterval(Double(step)).formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
      "SILTA_ID_SEED": "0",
    ]) { _, fixed in fixed }
  }

  /// The step's directory inside the scratch directory. Scenarios are repository-owned,
  /// so refusing absolute paths and `..` is enough to keep a typo inside the scratch.
  static func workingDirectory(_ relative: String, scratch: URL) throws -> URL {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
      throw ScenarioFailure(description: "cwd escapes the scenario scratch directory: \(relative)")
    }
    return scratch.appending(path: relative)
  }

  static func terminationMismatch(_ actual: Termination, expected: Int32) -> String? {
    actual == .exit(expected) ? nil : "exit expected \(expected), actual \(actual)"
  }

  @discardableResult
  static func run(_ file: URL, in scratch: URL, evidence: URL? = nil) throws -> Data {
    let evidence =
      evidence
      ?? repository.appending(
        path:
          "artifacts/scenarios/\(UUID().uuidString)/\(file.deletingPathExtension().lastPathComponent)"
      )
    let bytes = try Data(contentsOf: file)
    var transcript = Data()
    var failure: String?
    do {
      let scenario = try Scenario.decode(String(contentsOf: file, encoding: .utf8))
      if scenario.fixtures == true { try fixtures(in: scratch) }
      for (index, step) in scenario.steps.enumerated() {
        try execute(step, index: index, scratch: scratch, transcript: &transcript)
      }
    } catch { failure = String(describing: error) }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    if let failure {
      try Data(("# First failure\n\n" + failure + "\n").utf8).write(
        to: evidence.appending(path: "failure.md"))
    }
    try transcript.write(to: evidence.appending(path: "transcript.ndjson"))
    try summary(bytes, passed: failure == nil, scratch: scratch)
      .write(to: evidence.appending(path: "summary.json"))
    if let failure { throw ScenarioFailure(description: "\(failure)\nEvidence: \(evidence.path)") }
    return transcript
  }

  private static func execute(
    _ step: Scenario.Step, index: Int, scratch: URL, transcript: inout Data
  ) throws {
    do {
      let cwd = try workingDirectory(step.cwd ?? ".", scratch: scratch)
      let env = environment(step: index, overrides: step.env ?? [:], scratch: scratch)
      let result = try SiltaBinary.runProcess(
        try SiltaBinary.url(), step.args,
        in: scratch, cwd: cwd, environment: env)
      var record: [String: Any] = [
        "args": step.args, "cwd": step.cwd ?? ".", "timestamp": env["SILTA_NOW"] ?? "",
        "stdout": result.stdout, "stderr": result.stderr,
        "termination": String(describing: result.termination),
      ]
      record["actor"] = env["SILTA_ACTOR"]
      record["session"] = env["SILTA_SESSION"]
      transcript += try json(record) + Data([10])
      if let mismatch = try mismatch(result, expectation: step.expect) {
        throw ScenarioFailure(description: mismatch)
      }
    } catch {
      throw ScenarioFailure(
        description: "Step \(index): silta \(step.args.joined(separator: " "))\n\n\(error)")
    }
  }

  private static func summary(_ bytes: Data, passed: Bool, scratch: URL) throws -> Data {
    let commit = try git(["rev-parse", "HEAD"], in: scratch).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let dirty = try !git(["status", "--porcelain"], in: scratch).isEmpty
    let version = try SiltaBinary.run(["--version"], in: scratch.appending(path: "metadata"))
    guard version.termination == .exit(0) else {
      throw ScenarioFailure(description: "Cannot read binary version")
    }
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return try json([
      "commit": commit, "dirty": dirty,
      "version": version.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      "scenario_sha256": hash, "passed": passed,
    ])
  }

  private static func fixtures(in scratch: URL) throws {
    let result = try AcmeFixtures.make(at: scratch.appending(path: "fixtures"))
    guard result.termination == .exit(0) else {
      throw ScenarioFailure(
        description: "fixture generation failed: \(result.termination)\n\(result.stderr)")
    }
  }

  private static func mismatch(_ result: CLIResult, expectation: Scenario.Expectation) throws
    -> String?
  {
    if let failure = terminationMismatch(result.termination, expected: expectation.exit) {
      return failure
    }
    if let name = expectation.stdout, let failure = goldenMismatch(result.stdout, golden: name) {
      return failure
    }
    if expectation.code != nil || expectation.json != nil {
      guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) else {
        return "code and json expectations need --json in args; stdout was not JSON"
      }
      if let code = expectation.code {
        let actual = ((object as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
        if actual != code { return "error.code expected \(code), actual \(actual ?? "missing")" }
      }
      for (path, expected) in (expectation.json ?? [:]).sorted(by: { $0.key < $1.key }) {
        let value = value(at: path, in: object)
        let expectedBytes = try JSONEncoder().encode(expected)
        guard let value else { return "JSON path \(path) is missing" }
        let actualBytes = try JSONSerialization.data(
          withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        if actualBytes != expectedBytes {
          return
            "JSON \(path) expected \(expected), actual \(value)"
        }
      }
    }
    return nil
  }

  private static func goldenMismatch(_ stdout: String, golden name: String) -> String? {
    let path = repository.appending(path: "Tests/siltaTests/Golden/\(name)")
    guard let expected = try? String(contentsOf: path, encoding: .utf8) else {
      return "golden \(name) not found in Tests/siltaTests/Golden"
    }
    return stdout == expected ? nil : "stdout expected:\n\(expected)\nactual:\n\(stdout)"
  }

  private static func value(at path: String, in object: Any) -> Any? {
    path.split(separator: ".").reduce(Optional(object)) { value, part in
      if let index = Int(part), let array = value as? [Any], array.indices.contains(index) {
        return array[index]
      }
      return (value as? [String: Any])?[String(part)]
    }
  }

  private static func git(_ args: [String], in scratch: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: repository)
    guard result.termination == .exit(0) else {
      throw ScenarioFailure(description: "Cannot read repository metadata")
    }
    return result.stdout
  }

  private static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}
