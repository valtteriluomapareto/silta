import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct DoctorWritabilityCommandTests {
  private let environment = ["SILTA_NOW": "2023-11-14T22:13:20.000Z"]

  @Test(arguments: ["file", "directory-write", "directory-search"])
  func deniedAccessReturnsEnvironmentFailure(kind: String) throws {
    try withScratchDirectory { scratch in
      try #require(
        SiltaBinary.run(["init"], in: scratch, environment: environment).termination == .exit(0))
      let home = scratch.appending(path: "silta-home")
      let file = home.appending(path: "silta.db")
      let target = kind == "file" ? file : home
      try FileManager.default.setAttributes(
        [.posixPermissions: kind == "file" ? 0o400 : kind == "directory-write" ? 0o500 : 0o600],
        ofItemAtPath: target.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: kind == "file" ? 0o600 : 0o700], ofItemAtPath: target.path)
      }  // restore fixture access
      #expect(
        kind == "directory-search"
          ? !FileManager.default.isExecutableFile(atPath: target.path)
          : !FileManager.default.isWritableFile(atPath: target.path))
      let result = try SiltaBinary.run(
        ["doctor", "--json"], in: scratch, environment: environment)
      #expect(result.termination == .exit(9))
      let json = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      #expect(json["ok"] as? Bool == false)
      let error = try #require(json["error"] as? [String: Any])
      #expect(error["code"] as? String == "env")
      #expect(error["next_by"] as? String == "human")
      #expect(!result.stdout.contains("silta init"))
      let data = try #require(json["data"] as? [String: Any])
      let checks = try #require(data["checks"] as? [[String: Any]])
      let check = try #require(checks.first { $0["id"] as? String == "database.writable" })
      #expect(check["status"] as? String == "fail")
      if kind == "file" {
        let encoded = try JSONSerialization.data(
          withJSONObject: check, options: [.sortedKeys, .withoutEscapingSlashes])
        let text = try #require(String(data: encoded, encoding: .utf8))
        Golden.forTests().check(
          text.replacingOccurrences(of: home.path, with: "<silta-home>") + "\n",
          "doctor-writable-failure.json")
      }
      let focused = try SiltaBinary.run(
        ["doctor", "--install", "--json"], in: scratch, environment: environment)
      #expect(focused.termination == .exit(0))
      #expect(!focused.stdout.contains("database."))
    }
  }

  @Test func fixesRequireExistingExplicitCommands() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["doctor", "--fix", "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("usage"))
      #expect(result.stdout.contains("silta doctor --help"))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      let help = try SiltaBinary.run(["doctor", "--help"], in: scratch)
      #expect(
        help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(
          "without repairs"))
      #expect(!help.stdout.contains("--fix"))
    }
  }
}
