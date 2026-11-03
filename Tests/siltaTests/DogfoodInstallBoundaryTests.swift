import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodInstallBoundaryTests {
  @Test(arguments: ["tracked", "head", "branch"])
  func changesDuringBuildNeverReplaceInstalledBinary(change: String) throws {
    try withScratchDirectory { scratch in
      let clone = try DogfoodToolingTests.clone(scratch)
      let tools = scratch.appending(path: "tools")
      let destination = scratch.appending(path: "installed/silta")
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("Acme original".utf8).write(to: destination)
      let action =
        change == "tracked"
        ? "echo Acme >> .gitignore"
        : change == "head"
          ? "git -c user.name=Acme -c user.email=acme@example.invalid commit --allow-empty -qm Acme"
          : "git checkout -qb codex/acme"
      try DogfoodReportTests.tool(
        "swift",
        text: "#!/bin/bash\nmkdir -p .build/release\necho Acme-candidate > .build/release/silta\n"
          + action + "\n", in: tools)
      let result = try DogfoodToolingTests.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination != .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme original")
    }
  }

  @Test func defaultInstallDirectoryUsesOnlyTheTemporaryHome() throws {
    try withScratchDirectory { scratch in
      let clone = try DogfoodToolingTests.clone(scratch)
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
