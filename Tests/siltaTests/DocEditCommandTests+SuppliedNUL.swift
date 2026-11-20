import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEditCommandTests {
  @Test(
    arguments: ["file", "stdin"].flatMap { channel in [false, true].map { (channel, $0) } }
      + [("human-file", true)])
  func suppliedNULRefusesWithoutWriting(input: (String, Bool)) throws {
    let (channel, allow) = input
    let human = channel == "human-file"
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let before = try DocEditPreparationCommandTests.truth(store)
      let body = "Acme\u{0}private-tail"
      let file = try Self.input(scratch, body)
      var result: CLIResult
      if human {
        result = try SiltaBinary.runProcess(
          URL(filePath: "/usr/bin/script"),
          ["-q", "/dev/null", try SiltaBinary.url().path, "--ws", "acme", "doc", "edit", "rules"]
            + Self.creation + ["-F", file.path, "--allow-secret", "--json"], in: scratch,
          environment: ["SILTA_ACTOR": "human:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
        result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "^D\u{08}\u{08}", with: "")
      } else if channel == "file" {
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
      do {
        if !human {
          #expect(result.termination == .exit(1) && result.stderr.isEmpty)
          #expect((error?["next"] as? [String])?.isEmpty == false)
        }
        #expect(error?["code"] as? String == "invalid")
        #expect(error?["message"] as? String == "Body input must not contain NUL bytes.")
        #expect(after == before)
      }
      #expect(!(result.stdout + result.stderr).contains("private-tail"))
    }
  }
}
