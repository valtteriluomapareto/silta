import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension StatusCommandTests {
  // Spec §16: inside an unregistered Git repository the fallback points at `where`,
  // which names the scan command, also before any storage exists.
  @Test func firstUseInsideGitPointsAtWhereWithoutCreatingStorage() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "acme-new")
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      let initialized = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/git"), ["init", "-q"], in: scratch, cwd: repo)
      try #require(initialized.termination == .exit(0), "\(initialized.stderr)")
      try withKnownIssue("SI-57/8: no database returns before checking Git") {
        for args in [[], ["status"], ["--quiet"]] {
          let result = try Self.silta(args, scratch, cwd: repo)
          #expect(
            result
              == CLIResult(
                termination: .exit(0), stdout: "No workspace here; next: silta where\n",
                stderr: ""),
            "\(args)")
        }
      }
      let json = try Self.silta(["--json"], scratch, cwd: repo)
      Golden.forTests().check(json.stdout, "status-none.json")
      let home = scratch.appending(path: "silta-home")
      for file in ["silta.db", "index.db"] {
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: file).path), "\(file)")
      }
    }
  }

  // The count is the inbox the caller sees without `--all`: a human's proposals older
  // than 14 days stay out of it, as they stay out of `silta inbox`.
  @Test func aHumanCountLeavesOutWhatTheInboxHidesWithoutAll() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let old = Self.caller.merging(["SILTA_NOW": "2023-10-01T00:00:00.000Z"]) { $1 }
      for (title, environment) in [("Acme old idea", old), ("Acme new idea", Self.caller)] {
        let added = try Self.silta(["task", "add", title], scratch, environment: environment)
        try #require(added.termination == .exit(0), "\(added.stderr)")
      }
      func human(_ args: [String]) throws -> String {
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/usr/bin/script"), ["-q", "/dev/null", try SiltaBinary.url().path] + args,
          in: scratch, environment: ["USER": "acme", "SILTA_NOW": "2023-11-14T22:13:23.000Z"])
        #expect(result.termination == .exit(0), "\(args) \(result.stdout)")
        // `script` echoes the closed stdin as `^D` and two backspaces.
        return result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      }
      let inbox = try #require(
        try JSONSerialization.jsonObject(with: Data(human(["inbox", "--json"]).utf8))
          as? [String: Any])
      let data = try #require(inbox["data"] as? [String: Any])
      #expect(data["actor"] as? String == "human:acme")
      #expect((data["items"] as? [Any])?.count == 1 && data["remaining"] as? Int == 0)
      #expect(try human([]) == "workspace acme, app (unregistered), inbox 1, claimed none\n")
    }
  }

  // Spec §16: `location` is always present; every other field is optional.
  @Test func schemaPublishesTheStatusShape() throws {
    try withScratchDirectory { scratch in
      let result = try Self.silta(["schema", "status", "--json"], scratch)
      let detail = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let entries = try #require(
        (detail["data"] as? [String: Any])?["commands"] as? [[String: Any]])
      let data = try #require(entries.first?["data"] as? [String: Any])
      let expected = try #require(
        try JSONSerialization.jsonObject(
          with: Data(
            """
            {"object":{"location":"string","workspace":{"optional":"string"},
              "app":{"optional":"string"},"inbox":{"optional":"int"},
              "claimed":{"optional":{"array":{"object":{"ref":"string","title":"string"}}}}}}
            """.utf8)) as? [String: Any])
      #expect(NSDictionary(dictionary: data) == NSDictionary(dictionary: expected))
    }
  }
}
