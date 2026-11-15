import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
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
