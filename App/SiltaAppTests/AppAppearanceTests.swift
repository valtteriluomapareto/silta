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

    @Test func inspectorWidthStaysWithinTheColumnRange() {
      #expect(SeaInspectorMetrics.clamped(SeaInspectorMetrics.width) == 340)
      #expect(SeaInspectorMetrics.clamped(120) == 300)
      #expect(SeaInspectorMetrics.clamped(900) == 500)
      #expect(SeaInspectorMetrics.range.contains(SeaInspectorMetrics.width))
    }
  }
#endif
