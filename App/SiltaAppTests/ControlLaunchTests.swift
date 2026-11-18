#if DEBUG
  import SiltaAppSupport
  @testable import SiltaApp
  import Testing

  @MainActor struct ControlLaunchTests {
    @Test func driverRunDirectoryRequiresInteractiveFixtureAndAbsolutePath() throws {
      let flags = ["-SiltaFixture", "v2", "-SiltaRunDirectory", "/private/tmp/silta-app-test"]
      let options = try #require(ControlLaunch.parse(flags))
      #expect(options.runDirectory?.path == "/private/tmp/silta-app-test")
      #expect(throws: AppLoadFailure.self) {
        try ControlLaunch.parse(flags + ["-SiltaSnapshot", "/private/tmp/root.png"])
      }
      #expect(throws: AppLoadFailure.self) {
        try ControlLaunch.parse(["-SiltaFixture", "v2", "-SiltaRunDirectory", "relative"])
      }
    }

    @Test func isolatedSnapshotLaunchAcceptsRouteAppearanceAndSize() throws {
      let arguments = [
        "SiltaApp", "-SiltaSnapshot", "/private/tmp/acme-snapshot.png",
        "-SiltaRoute", "board:AC-12", "-SiltaDark", "-SiltaSize", "1280x800",
      ]
      let accepted: Bool
      do { accepted = try FixtureLaunch.parse(arguments) } catch { accepted = false }
      #expect(accepted)
      let options = try #require(try ControlLaunch.parse(arguments))
      #expect(options.route.screen == .board && options.route.ref == "AC-12")
      #expect(options.dark && options.width == 1280 && options.height == 800)
    }
    @Test(arguments: ["sidebar.png", "inspector.png", "SIDEBAR.PNG"])
    func sidecarNamesCannotReplaceTheRequestedRoot(_ name: String) {
      #expect(throws: AppLoadFailure.self) {
        try ControlLaunch.parse(["SiltaApp", "-SiltaSnapshot", "/private/tmp/" + name])
      }
    }

    @Test(arguments: [
      ["-SiltaRoute", "board"], ["-SiltaSnapshot"],
      ["-SiltaSnapshot", "acme.txt"], ["-SiltaFixture", "v2", "-SiltaUnknown"],
      ["-SiltaFixture", "v2", "-SiltaDark", "-SiltaDark"],
      ["-SiltaSnapshot", "acme.png", "-SiltaSize", "0x800"],
      ["-SiltaSnapshot", "acme.png", "-SiltaSize", "1280x-1"],
      ["-SiltaSnapshot", "acme.png", "-SiltaRoute", "missing-screen"],
      ["-SiltaSnapshot", "acme.png", "-SiltaRoute", "mywork:AC-12"],
    ]) func invalidControlOptionsRefuseBeforeSeeding(_ arguments: [String]) {
      #expect(throws: AppLoadFailure.self) { try ControlLaunch.parse(arguments) }
    }
  }
#endif
