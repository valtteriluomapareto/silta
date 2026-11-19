import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct BodyInputCommandTests {
  static let maximumBytes = 65_536
  static let originalPlan = "- [ ] Acme original"

  @discardableResult
  static func setupPlan(in scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    let opts = TaskCommandTests.actor
    let added = try SiltaBinary.run(
      ["task", "add", "Acme body", "--start"], in: scratch, environment: opts)
    try #require(added.termination == .exit(0))
    let planned = try SiltaBinary.run(
      ["task", "plan", "AC-1", "-m", originalPlan], in: scratch, environment: opts)
    try #require(planned.termination == .exit(0))
    return store
  }

  static func oversizedPlan() -> Data {
    let start = Data("- [ ] Acme changed\n\n".utf8)
    return start + Data(repeating: 97, count: maximumBytes + 1 - start.count)
  }

  @Test func oversizedRegularFileCannotReplaceStoredPlan() throws {
    try withScratchDirectory { scratch in
      try Self.setupPlan(in: scratch)
      let file = scratch.appending(path: "Acme body.md")
      try Self.oversizedPlan().write(to: file)
      let args = ["--ws", "acme", "task", "plan", "AC-1", "-F", file.path, "--json"]
      let result = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.actor)
      let payload = try GuideContractTests.object(result.stdout)["error"] as? [String: Any]
      let stored = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(1))
      #expect(payload?["code"] as? String == "invalid")
      #expect((payload?["message"] as? String)?.contains("65536") == true)
      #expect(stored.stdout.contains(Self.originalPlan))
    }
  }
}
