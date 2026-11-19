import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ManagedDirectoryCommandTests {
  @Test(arguments: [
    ["backup"], ["export", "--ws", "acme"], ["export", "--ws", "acme", "--commit"],
  ])
  func managedDirectoryRefusalNamesDoctor(arguments: [String]) throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let fm = FileManager.default
      let home = scratch.appending(path: "silta-home")
      let name = arguments.first == "backup" ? "backups" : "exports"
      let directory = home.appending(path: name)
      let other = home.appending(path: "acme-empty")
      if fm.fileExists(atPath: directory.path) {
        try fm.moveItem(at: directory, to: home.appending(path: "original-" + name))
      }
      try fm.createDirectory(at: other, withIntermediateDirectories: false)
      try fm.createSymbolicLink(at: directory, withDestinationURL: other)

      for json in [false, true] {
        let result = try SiltaBinary.run(arguments + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(9))
        let output = json ? result.stdout : result.stderr
        let golden = name == "exports" ? "export-linked-default-root" : "backup-linked-root"
        Golden.forTests().check(output, golden + (json ? ".json" : ".txt"))
        #expect(try fm.contentsOfDirectory(atPath: other.path).isEmpty)
      }
      let doctor = try SiltaBinary.run(
        ["doctor", "--json"], in: scratch, environment: ExportCommandTests.environment)
      let diagnostic = name == "exports" ? "data.exports" : "data.backup"
      let envelope = try #require(
        try JSONSerialization.jsonObject(with: Data(doctor.stdout.utf8)) as? [String: Any])
      let data = try #require(envelope["data"] as? [String: Any])
      let checks = try #require(data["checks"] as? [[String: Any]])
      let check = try #require(checks.first { $0["id"] as? String == diagnostic })
      let next = try #require((check["next"] as? [String])?.first)
      #expect(next.hasPrefix("/bin/ls -ld "))
      #expect(next.contains(directory.path))
      let inspected = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", next], in: scratch)
      #expect(inspected.termination == .exit(0))
      #expect(inspected.stdout.contains(" -> "))
      #expect(try fm.contentsOfDirectory(atPath: other.path).isEmpty)
    }
  }
}
