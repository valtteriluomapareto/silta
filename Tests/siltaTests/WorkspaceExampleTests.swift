import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceExampleTests {
  @Test func documentedAcmeWorkspaceAppliesAndShowsApps() throws {
    try withScratchDirectory { scratch in
      let example = DogfoodReportTests.root.appending(path: "docs/examples/acme-workspace.yaml")
      let edited = try SiltaBinary.run(
        [
          "ws", "edit", "-F", example.path,
          "--approved", "Apply the Acme example.",
        ], in: scratch, environment: TaskCommandTests.actor)
      #expect(edited.termination == .exit(0), "\(edited.stderr)")

      let shown = try SiltaBinary.run(["ws", "show", "acme", "--json"], in: scratch)
      #expect(shown.termination == .exit(0), "\(shown.stderr)")
      let envelope = try #require(
        JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])
      let data = try #require(envelope["data"] as? [String: Any])
      let yaml = try #require(data["yaml"] as? String)
      let apps = try #require(yaml.components(separatedBy: "\napps:\n").last)
        .components(separatedBy: "\nenvironments:")[0]
      for app in [
        "platform-legacy", "platform-portal", "platform-crm-ui", "platform-api",
        "mobile", "sales", "pdf-service",
      ] {
        #expect(apps.contains("\"slug\":\"\(app)\""))
      }
    }
  }
}
