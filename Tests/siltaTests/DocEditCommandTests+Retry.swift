import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
  @Test func newStdinDocumentRetryPreservesSafeMetadata() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let title = "-Acme's rules"
      let input = [
        "rules", "-F", "-", "--title=" + title, "--kind", "flow", "--about", "service:push",
      ]
      let result = try Self.run(input, scratch, approved: false)
      #expect(result.termination == .exit(3))
      let next = try #require((try Self.error(result)["next"] as? [String])?.first)
      let expected =
        "silta --ws 'acme' doc edit 'doc:rules' -F - --title=" + shellWord(title)
        + " --kind 'flow' --about 'service:push' --approved \"<the human's words>\""
      #expect(next == expected)
      let text = try SiltaBinary.run(
        ["--ws", "acme", "doc", "edit"] + input, in: scratch, environment: TaskCommandTests.fixed)
      #expect(text.termination == .exit(3) && text.stderr.contains("ask human: " + next))
      let file = try Self.input(scratch, "Acme document")
      let retry =
        shellWord(try SiltaBinary.url().path)
        + String(next.dropFirst("silta".count))
        .replacingOccurrences(of: "<the human's words>", with: "Create the Acme document")
        + " < " + shellWord(file.path)
      let replay = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", retry], in: scratch, environment: TaskCommandTests.fixed)
      #expect(replay.termination == .exit(0))
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT title FROM doc_rev") } == title)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT body_md FROM doc_rev") }
          == "Acme document")
      let audit = try store.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
      #expect(audit?.contains("-F <file> --title <title> --kind <kind> --about <ref>") == true)
      let unsafe = try Self.run(
        ["other", "-F", "-", "--title", Self.secret, "--about", "service:push"],
        scratch, approved: false)
      #expect(unsafe.termination == .exit(3))
      #expect(try Self.error(unsafe)["next_by"] as? String == "agent")
      #expect(!unsafe.stdout.contains(Self.secret))
    }
  }
}
