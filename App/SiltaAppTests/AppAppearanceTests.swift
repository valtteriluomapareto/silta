#if DEBUG
  import AppKit
  @testable import SiltaApp
  import Testing

  struct AppAppearanceTests {
    @Test func storedValuesAndAppKitAppearancesAreStable() {
      #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
      #expect(AppAppearance.system.appearanceName == nil)
      #expect(AppAppearance.light.appearanceName == .aqua)
      #expect(AppAppearance.dark.appearanceName == .darkAqua)
      #expect(AppAppearance(rawValue: "sepia") == nil)
    }
  }
#endif
