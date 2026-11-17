#if DEBUG
  import SiltaAppSupport
  @testable import SiltaApp
  import Testing

  struct ControlLaunchTests {
    @Test func isolatedSnapshotLaunchAcceptsRouteAppearanceAndSize() {
      let arguments = [
        "SiltaApp", "-SiltaSnapshot", "/private/tmp/acme-snapshot.png",
        "-SiltaRoute", "board:AC-12", "-SiltaDark", "-SiltaSize", "1280x800",
      ]
      let accepted: Bool
      do { accepted = try FixtureLaunch.parse(arguments) } catch { accepted = false }
      withKnownIssue("Debug fixture launch does not accept snapshot options yet") {
        #expect(accepted)
      }
    }
  }
#endif
