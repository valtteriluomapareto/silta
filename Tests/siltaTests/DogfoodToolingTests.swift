import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct DogfoodToolingTests {
  static func git(_ args: [String], in scratch: URL, cwd: URL) throws -> String {
    let result = try SiltaBinary.runProcess(URL(filePath: "/usr/bin/git"), args,
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
    _ = try git(["add", "."], in: scratch, cwd: origin)
    _ = try git(["-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm", "Acme installer"], in: scratch, cwd: origin)
    let clone = scratch.appending(path: "clone")
    _ = try git(["clone", "-q", origin.path, clone.path], in: scratch, cwd: scratch)
    return clone
  }

  static func install(_ clone: URL, scratch: URL, tools: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(URL(filePath: "/bin/bash"),
      [clone.appending(path: "scripts/install-dev.sh").path], in: scratch,
      environment: ["PATH": tools.path + ":/usr/bin:/bin",
        "SILTA_INSTALL_DIR": scratch.appending(path: "installed").path])
  }

  @Test func installerRefusesDirtyOtherBranchAndDetachedBeforeBuild() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      try DogfoodReportTests.tool("swift", text: "#!/bin/bash\necho called >> " + shellWord(scratch.appending(path: "build-called").path) + "\nexit 99\n", in: tools)
      try Data("Acme untracked".utf8).write(to: clone.appending(path: "untracked"))
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      try FileManager.default.removeItem(at: clone.appending(path: "untracked"))
      _ = try Self.git(["checkout", "-qb", "codex/acme"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      _ = try Self.git(["checkout", "--detach", "-q"], in: scratch, cwd: clone)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "build-called").path))
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "installed/silta").path))
    }
  }

  @Test func installerBuildsCleanMainAndPreservesExistingBinaryOnFailure() throws {
    try withScratchDirectory { scratch in
      let clone = try Self.clone(scratch)
      let tools = scratch.appending(path: "tools")
      let destination = scratch.appending(path: "installed/silta")
      try DogfoodReportTests.tool("swift", text: """
        #!/bin/bash
        [[ "$*" == 'build -c release --only-use-versions-from-resolved-file' ]] || exit 98
        mkdir -p .build/release
        printf 'Acme binary' > .build/release/silta
        """, in: tools)
      let result = try Self.install(clone, scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
      let commit = try Self.git(["rev-parse", "HEAD"], in: scratch, cwd: clone)
      #expect(result.stdout.contains(commit) && result.stdout.contains("Next:"))
      try DogfoodReportTests.tool("swift", text: "#!/bin/bash\nexit 42\n", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
      try FileManager.default.removeItem(at: clone.appending(path: ".build"))
      try DogfoodReportTests.tool("swift", text: "#!/bin/bash\nexit 0\n", in: tools)
      #expect(try Self.install(clone, scratch: scratch, tools: tools).termination != .exit(0))
      #expect(try String(contentsOf: destination, encoding: .utf8) == "Acme binary")
    }
  }

  static func importStore(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write { tx in
      try tx.database.execute(sql: """
        INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('silta','silta','Acme Silta','SI');
        INSERT INTO repo(uid,workspace_id,slug) VALUES('silta-repo',2,'silta');
        INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
        VALUES('silta-app',2,'silta','Acme Silta',1,'main');
        """)
    }
    return store
  }

  @Test func paginatedIssueImportIsIdempotentAndExplicitlyScoped() throws {
    try withScratchDirectory { scratch in
      let store = try Self.importStore(scratch)
      let tools = scratch.appending(path: "tools")
      try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: tools.appending(path: "silta"), withDestinationURL: SiltaBinary.url())
      let other = (1...31).map { ["number": $0, "title": "Acme documentation", "html_url": "https://example.com/acme/\($0)"] as [String: Any] }
      let match: [String: Any] = ["number": 40, "title": "S7: Acme location", "html_url": "https://example.com/acme/40"]
      let data = try JSONSerialization.data(withJSONObject: [other, [match, match,
        ["number": 41, "title": "DF: Acme report", "html_url": "https://example.com/acme/41"],
        ["number": 42, "title": "S99: Acme pull request", "html_url": "https://example.com/acme/42", "pull_request": [:]]]])
      let pages = scratch.appending(path: "pages.json")
      try data.write(to: pages)
      try DogfoodReportTests.tool("gh", text: "#!/bin/bash\n[[ \"$1 $2 $3\" == 'api --paginate --slurp' ]] || exit 98\ncat " + shellWord(pages.path) + "\n", in: tools)
      for _ in 0..<2 {
        let result = try SiltaBinary.runProcess(URL(filePath: "/bin/bash"),
          [DogfoodReportTests.root.appending(path: "scripts/dogfood-import-issues.sh").path], in: scratch,
          environment: ["PATH": tools.path + ":/usr/bin:/bin", "SILTA_ACTOR": ActorID.agent(tool: "codex", session: "acme").description])
        #expect(result.termination == .exit(0) && result.stdout.contains("Next:"))
      }
      try store.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT workspace_id,status,app_id FROM task")
        #expect(rows.count == 2 && rows.allSatisfy { $0["workspace_id"] as Int64 == 2 && $0["app_id"] as Int64 == 1 })
        #expect(rows.allSatisfy { $0["status"] as String == "proposed" })
        let links = try String.fetchAll(db, sql: "SELECT to_ext FROM link ORDER BY to_ext")
        #expect(links == ["https://example.com/acme/40", "https://example.com/acme/41"])
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
      }
    }
  }
}
