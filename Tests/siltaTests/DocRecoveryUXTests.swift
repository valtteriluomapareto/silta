import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocRecoveryUXTests {
  @Test func defaultGuideHasOnlyDocDecisionsAndStdinExamples() throws {
    try withScratchDirectory { scratch in
      let full = try SiltaBinary.run(["guide"], in: scratch)
      let docs = try SiltaBinary.run(["guide", "docs"], in: scratch)
      #expect(full.termination == .exit(0) && docs.termination == .exit(0))
      let section = try #require(full.stdout.components(separatedBy: "# Workspace docs\n").last)
        .components(separatedBy: "# Working for the human\n")[0]
      #expect(section.split(separator: "\n").count <= 8)
      #expect(!full.stdout.contains(docs.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
      #expect(docs.stdout.contains("-F -") && docs.stdout.contains("<<'DOC'"))
      #expect(!docs.stdout.contains("-F rules.md") && !docs.stdout.contains("-F api.md"))
      #expect(docs.stdout.contains("Map gap:") && docs.stdout.contains("doc triage --accept"))
    }
  }

  @Test(arguments: ["json", "quiet", "text"], [false, true])
  func blankProposalFileAndStdinRefuseWithoutRows(mode: String, stdin: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try DocEditCommandTests.input(scratch, " \t\n")
      let args =
        ["--ws", "acme", "doc", "propose", "rules"] + DocEditCommandTests.creation
        + ["-m", "Share Acme", "-F", stdin ? "-" : file.path]
        + (mode == "text" ? [] : ["--" + mode])
      let before = try truth(store)
      let result =
        try stdin
        ? SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"),
          [
            "-c", #"file=$2; binary=$1; shift 2; exec "$binary" "$@" < "$file""#,
            "_", try SiltaBinary.url().path, file.path,
          ] + args,
          in: scratch, environment: TaskCommandTests.fixed)
        : SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      if mode == "json" { Golden.forTests().check(result.stdout, "doc-propose-blank.json") }
      #expect(try truth(store) == before)
    }
  }

  @Test(arguments: ["archived", "bare-app"])
  func recoveryReadsTheRelevantHistoryOrTypedItem(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "app", in: store, archived: mode == "archived")
      let args =
        mode == "archived"
        ? ["doc", "show", "doc:rules@99"] : ["doc", "ls", "--about", "api"]
      let before = try truth(store)
      let refused = try SiltaBinary.run(["--ws", "acme"] + args + ["--json"], in: scratch)
      let error = try DocEditCommandTests.error(refused)
      let next = try #require((error["next"] as? [String])?.first)
      #expect(next.contains(mode == "archived" ? "--archived" : "--about 'app:api'"))
      let read = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "\"$1\"" + next.dropFirst("silta".count) + " --json", "_",
          try SiltaBinary.url().path,
        ], in: scratch, environment: TaskCommandTests.fixed)
      #expect(read.termination == .exit(0) && read.stdout.contains("doc:rules@1"))
      #expect(try truth(store) == before)
    }
  }

  private func truth(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      try ["doc", "doc_rev", "link", "approval", "seq_counter", "change_log", "meta"].map {
        try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")
      }
    }
  }
}
