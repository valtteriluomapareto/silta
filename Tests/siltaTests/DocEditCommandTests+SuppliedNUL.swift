import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
  @Test func terminalHumanCannotAllowSuppliedNUL() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let before = try DocEditPreparationCommandTests.truth(store)
      let file = try Self.input(scratch, "Acme\u{0}private-tail")
      var result = try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/script"),
        ["-q", "/dev/null", try SiltaBinary.url().path, "--ws", "acme", "doc", "edit", "rules"]
          + Self.creation + ["-F", file.path, "--allow-secret", "--json"], in: scratch,
        environment: ["SILTA_ACTOR": "human:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = object["error"] as? [String: Any]
      let after = try DocEditPreparationCommandTests.truth(store)
      withKnownIssue("SI-129: direct humans can supply NUL bodies") {
        #expect(error?["code"] as? String == "invalid")
        #expect(error?["message"] as? String == "Doc input must not contain NUL bytes.")
        #expect(after == before)
      }
      #expect(!(result.stdout + result.stderr).contains("private-tail"))
    }
  }

  @Test(arguments: ["file", "stdin"], [false, true])
  func suppliedNULRefusesWithoutWriting(channel: String, allow: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let before = try DocEditPreparationCommandTests.truth(store)
      let body = "Acme\u{0}private-tail"
      let file = try Self.input(scratch, body)
      let result: CLIResult
      if channel == "file" {
        result = try Self.run(
          ["rules"] + Self.creation + ["-F", file.path] + (allow ? ["--allow-secret"] : []), scratch
        )
      } else {
        result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"),
          [
            "-c",
            "exec \"$1\" --ws acme doc edit rules --title Rules --about service:push"
              + " -F - --approved 'Keep these rules' --json"
              + (allow ? " --allow-secret" : "") + " < \"$2\"",
            "_", try SiltaBinary.url().path, file.path,
          ],
          in: scratch, environment: TaskCommandTests.fixed)
      }
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = object["error"] as? [String: Any]
      let after = try DocEditPreparationCommandTests.truth(store)
      withKnownIssue("SI-129: file and stdin doc edits accept NUL") {
        #expect(result.termination == .exit(1) && result.stderr.isEmpty)
        #expect(error?["code"] as? String == "invalid")
        #expect(error?["message"] as? String == "Doc input must not contain NUL bytes.")
        #expect((error?["next"] as? [String])?.isEmpty == false)
        #expect(after == before)
      }
      #expect(!(result.stdout + result.stderr).contains("private-tail"))
    }
  }
}
