import Foundation
import SiltaTestSupport
import Testing

/// Every `silta …` an error tells the caller to run must exist (spec §16), or be
/// planned in a slice. The error goldens hold every coded error's text form.
@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct NextCommandTests {
  /// Commands that errors may name before their slice ships. Remove each when it lands.
  static let planned: [String: String] = [:]

  @Test func everySuggestedCommandExists() throws {
    let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var suggested: Set<String> = []
    for target in ["SiltaCoreTests", "siltaTests"] {
      let golden = tests.appending(path: "\(target)/Golden")
      for name in try FileManager.default.contentsOfDirectory(atPath: golden.path)
      // error-codes.txt renders synthetic sample errors, one per code.
      where name.hasSuffix(".txt") && name != "error-codes.txt" {
        let text = try String(contentsOf: golden.appending(path: name), encoding: .utf8)
        for line in text.split(separator: "\n") {
          for prefix in ["next: silta", "ask human: silta"] where line.hasPrefix(prefix) {
            // The command words, up to the first flag, placeholder or argument value.
            let words = line.dropFirst(prefix.count - "silta".count).split(separator: " ")
              .prefix { $0.allSatisfy { $0.isLowercase || $0 == "-" } && !$0.hasPrefix("-") }
            suggested.insert(words.joined(separator: " "))
          }
        }
      }
    }
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["schema", "--json"], in: scratch)
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let data = try #require(envelope["data"] as? [String: Any])
      let commands = try #require(data["commands"] as? [[String: Any]])
      let known = Set(commands.compactMap { $0["name"] as? String } + ["silta"])
      #expect(suggested.count >= 4, "too few suggestions found: \(suggested)")
      for command in suggested {
        let exists =
          known.contains(command)
          || Self.planned.keys.contains { command == $0 || command.hasPrefix($0 + " ") }
        #expect(exists, "\(command) is suggested but doesn't exist")
      }
    }
  }
}
