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

      let shown = try SiltaBinary.run(["ws", "show", "acme"], in: scratch)
      #expect(shown.termination == .exit(0), "\(shown.stderr)")
      for app in [
        "platform-legacy", "platform-portal", "platform-crm-ui", "platform-api",
        "mobile", "sales", "pdf-service",
      ] {
        #expect(shown.stdout.contains(app))
      }
    }
  }
}
