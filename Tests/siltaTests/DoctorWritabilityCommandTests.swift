import Darwin
import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct DoctorWritabilityCommandTests {
  private let environment = ["SILTA_NOW": "2023-11-14T22:13:20.000Z"]

  private func permissions(_ file: FileHandle) throws -> Int {
    var info = stat()
    try #require(fstat(file.fileDescriptor, &info) == 0)
    return Int(info.st_mode & 0o7777)
  }

  private func permissions(_ directory: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    ).intValue
  }

  @Test(arguments: ["file", "directory-write", "directory-search"])
  func deniedAccessReturnsEnvironmentFailure(kind: String) throws {
    try withScratchDirectory { scratch in
      try #require(
        SiltaBinary.run(["init"], in: scratch, environment: environment).termination == .exit(0))
      let home = scratch.appending(path: "silta-home")
      let file = home.appending(path: "silta.db")
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }  // best-effort fixture cleanup
      let target = kind == "file" ? file : home
      try FileManager.default.setAttributes(
        [.posixPermissions: kind == "file" ? 0o400 : kind == "directory-write" ? 0o500 : 0o600],
        ofItemAtPath: target.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: kind == "file" ? 0o600 : 0o700], ofItemAtPath: target.path)
      }  // restore fixture access
      try #require(
        kind == "directory-search"
          ? !FileManager.default.isExecutableFile(atPath: target.path)
          : !FileManager.default.isWritableFile(atPath: target.path))
      let fileMode = try permissions(handle)
      let directoryMode = try permissions(home)
      let result = try SiltaBinary.run(
        ["doctor", "--json"], in: scratch, environment: environment)
      #expect(try permissions(handle) == fileMode)
      #expect(try permissions(home) == directoryMode)
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

extension DoctorWritabilityCommandTests {
  @Test func danglingDatabaseLinkRequiresInspection() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "silta-home")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: home.appending(path: "backups"), withIntermediateDirectories: false)
      let link = home.appending(path: "silta.db")
      try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: scratch.appending(path: "Acme missing.db"))
      let result = try SiltaBinary.run(["doctor", "--json"], in: scratch, environment: environment)
      let payload = try GuideContractTests.object(result.stdout)
      let checks = try #require((payload["data"] as? [String: Any])?["checks"] as? [[String: Any]])
      let writable = try #require(checks.first { $0["id"] as? String == "database.writable" })
      let error = try #require(payload["error"] as? [String: Any])
      #expect(result.termination == .exit(9))
      withKnownIssue("Doctor treats a dangling link as an absent database") {
        #expect(writable["status"] as? String == "fail")
        let hints = error["next"] as? [String] ?? []
        #expect(hints.contains { $0.hasPrefix("/bin/ls ") })
        #expect(!hints.contains("silta init"))
      }
    }
  }

  @Test func doctorWarnsAboutLooseModesWithoutChangingThem() throws {
    try withScratchDirectory { scratch in
      try #require(
        SiltaBinary.run(["init"], in: scratch, environment: environment).termination == .exit(0))
      let home = scratch.appending(path: "silta-home")
      let paths = [
        (home, 0o755), (home.appending(path: "silta.db"), 0o644),
        (home.appending(path: "backups"), 0o755),
      ]
      for (url, mode) in paths {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
      }
      let result = try SiltaBinary.run(["doctor", "--json"], in: scratch, environment: environment)
      let data = try TaskStateCommandTests.data(result)
      let checks = try #require(data["checks"] as? [[String: Any]])
      let advisory = checks.first { $0["id"] as? String == "data.permissions" }
      withKnownIssue("Doctor does not report existing loose data modes") {
        #expect(advisory?["status"] as? String == "warning")
        #expect(advisory?["next_by"] as? String == "human")
      }
      for (url, mode) in paths { #expect(try permissions(url) == mode) }
      #expect(result.termination == .exit(0))
    }
  }
}
