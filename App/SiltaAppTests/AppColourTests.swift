#if DEBUG
  import AppKit
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import SwiftUI
  import Testing

  @MainActor struct AppColourTests {
    @Test func paletteHasEightDistinctAssetColours() throws {
      #expect(
        AppPalette.colours == [
          "AppIndigo", "AppBlue", "AppViolet", "AppPlum", "AppRose", "AppClay", "AppBrown",
          "AppSlate",
        ])
      #expect(
        AppPalette.colours.map(AppPalette.title) == [
          "Indigo", "Blue", "Violet", "Plum", "Rose", "Clay", "Brown", "Slate",
        ])
      for name in AppPalette.colours { #expect(NSColor(named: name) != nil, "\(name)") }
    }

    @Test(arguments: ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"])
    func everyColourReadsAsTextOnACard(appearance: String) throws {
      let look = try #require(NSAppearance(named: NSAppearance.Name(appearance)))
      let card = try Self.resolved("Card", look).withAlphaComponent(1)
      for name in AppPalette.colours {
        #expect(Self.contrast(try Self.resolved(name, look), card) >= 4.5, "\(name) \(appearance)")
      }
    }

    /// An app colour must never read as a status, and hues must stay apart (CIEDE2000).
    @Test(arguments: ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"])
    func coloursStayApartFromStatusesAndEachOther(appearance: String) throws {
      let look = try #require(NSAppearance(named: NSAppearance.Name(appearance)))
      let statuses = [
        "Success", "Warning", "AttentionMarker", "TideText", "Danger", "SecondaryInk",
      ]
      let palette = try AppPalette.colours.map { ($0, try Self.resolved($0, look)) }
      for (name, colour) in palette {
        for status in statuses {
          let distance = Self.deltaE(colour, try Self.resolved(status, look))
          #expect(distance >= 10, "\(name) vs \(status) \(appearance): \(distance)")
        }
      }
      for (index, (name, colour)) in palette.enumerated() {
        for (other, second) in palette.dropFirst(index + 1) {
          let distance = Self.deltaE(colour, second)
          #expect(distance >= 9, "\(name) vs \(other) \(appearance): \(distance)")
        }
      }
    }

    @Test func automaticColoursAreStablePerSlugNotByPosition() {
      let colour = AppPalette.automatic("acme-web")
      #expect(AppPalette.colours.contains(colour))
      #expect(AppPalette.automatic("acme-web") == colour)
      let slugs = ["acme-mobile", "acme-backend", "acme-web"]
      let before = slugs.map(AppPalette.automatic)
      let after = (["acme-admin"] + slugs).map(AppPalette.automatic).dropFirst()
      #expect(Array(after) == before)
      #expect(
        (slugs + ["acme-admin"]).map { AppPalette.title(AppPalette.automatic($0)) } == [
          "Slate", "Violet", "Blue", "Indigo",
        ])
    }

    @Test func aChosenColourIsKeptPerWorkspaceAndAppOnThisMac() async throws {
      try await fixture { reader in
        let defaults = Self.defaults()
        let model = Self.model(reader, defaults)
        await model.refresh().value
        let automatic = AppPalette.automatic("acme-web")
        #expect(model.appColour("acme-web") == automatic)
        let chosen = try #require(AppPalette.colours.first { $0 != automatic })
        model.setAppColour(chosen, for: "acme-web")
        #expect(model.appColour("acme-web") == chosen)
        #expect(model.chosenAppColours["acme-web"] == chosen)
        #expect(model.appColour("acme-mobile") == AppPalette.automatic("acme-mobile"))

        defaults.set(
          defaults.dictionary(forKey: AppModel.appColoursKey)?.merging(
            ["other": ["acme-web": "AppPlum"], "broken": "AppPlum"]
          ) { current, _ in current }, forKey: AppModel.appColoursKey)
        let relaunched = Self.model(reader, defaults)
        await relaunched.refresh().value
        #expect(relaunched.appColour("acme-web") == chosen)
        relaunched.setAppColour(nil, for: "acme-web")
        #expect(relaunched.appColour("acme-web") == automatic)
        #expect(Self.model(reader, defaults).chosenAppColours.isEmpty)

        let automated = Self.model(reader, nil)
        await automated.refresh().value
        automated.setAppColour(chosen, for: "acme-mobile")
        #expect(automated.appColour("acme-mobile") == chosen)
        let stored = defaults.dictionary(forKey: AppModel.appColoursKey) ?? [:]
        #expect(stored["acme"] == nil && stored["other"] != nil)
        #expect(Self.model(reader, defaults).chosenAppColours.isEmpty)
      }
    }

    @Test func everySurfaceUsesTheChosenColour() throws {
      try fixture { reader in
        let snapshot = try reader.snapshot(workspace: "acme")
        let apps = try reader.workspaceMap(workspace: "acme").apps
        let chosen = ["acme-web": "AppRose"]
        #expect(SidebarContent.appColor(slug: "acme-web", apps: apps, chosen: chosen) == "AppRose")
        #expect(
          SidebarContent.appColor(slug: "acme-mobile", apps: apps, chosen: chosen)
            == AppPalette.automatic("acme-mobile"))
        #expect(SidebarContent.appColor(slug: "gone", apps: apps, chosen: chosen) == nil)
        let map = try reader.workspaceMap(workspace: "acme")
        #expect(DocsAboutMenu.color("app:acme-web", map: map, chosen: chosen) == Color("AppRose"))
        #expect(
          DocsAboutMenu.color("app:acme-mobile", map: map, chosen: chosen)
            == Color(AppPalette.automatic("acme-mobile")))
        let board = BoardContent(
          snapshot: snapshot, apps: apps, filter: BoardFilter(), search: "", colours: chosen)
        let web = try #require(snapshot.board.todo.first { $0.app == "acme-web" })
        #expect(board.appLabel(for: web)?.color == "AppRose")
      }
    }

    private static func resolved(_ name: String, _ look: NSAppearance) throws -> NSColor {
      var colour: NSColor?
      look.performAsCurrentDrawingAppearance {
        colour = NSColor(named: name)?.usingColorSpace(.sRGB)
      }
      return try #require(colour, "\(name)")
    }

    private static func lab(_ c: NSColor) -> SIMD3<Double> {
      func linear(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      let (r, g, b) = (linear(c.redComponent), linear(c.greenComponent), linear(c.blueComponent))
      let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
      let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
      let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
      func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
      return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIEDE2000 colour difference.
    private static func deltaE(_ first: NSColor, _ second: NSColor) -> Double {
      let (one, two) = (lab(first), lab(second))
      let (l1, a1, b1) = (one.x, one.y, one.z)
      let (l2, a2, b2) = (two.x, two.y, two.z)
      let rad = Double.pi / 180
      let cBar = (hypot(a1, b1) + hypot(a2, b2)) / 2
      let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
      let (ap1, ap2) = ((1 + g) * a1, (1 + g) * a2)
      let (cp1, cp2) = (hypot(ap1, b1), hypot(ap2, b2))
      func hue(_ b: Double, _ a: Double) -> Double {
        let h = atan2(b, a) / rad
        return h < 0 ? h + 360 : h
      }
      let (h1, h2) = (hue(b1, ap1), hue(b2, ap2))
      var dh = h2 - h1
      if cp1 * cp2 == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
      let dH = 2 * sqrt(cp1 * cp2) * sin(dh * rad / 2)
      let lBar = (l1 + l2) / 2
      let cpBar = (cp1 + cp2) / 2
      var hBar = h1 + h2
      if cp1 * cp2 != 0 {
        hBar = abs(h1 - h2) <= 180 ? (h1 + h2) / 2 : (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2
      }
      let t =
        1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad)
        + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
      let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
      let sc = 1 + 0.045 * cpBar
      let sh = 1 + 0.015 * cpBar * t
      let theta = 30 * exp(-pow((hBar - 275) / 25, 2))
      let rc = 2 * sqrt(pow(cpBar, 7) / (pow(cpBar, 7) + pow(25, 7)))
      let rt = -sin(2 * theta * rad) * rc
      let (dl, dc, dhs) = ((l2 - l1) / sl, (cp2 - cp1) / sc, dH / sh)
      return sqrt(dl * dl + dc * dc + dhs * dhs + rt * dc * dhs)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
      func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
          let v = Double(v)
          return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
          + 0.0722 * channel(c.blueComponent)
      }
      let (x, y) = (luminance(a), luminance(b))
      return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func defaults() -> UserDefaults {
      let name = "silta-tests-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: name)
      defaults?.removePersistentDomain(forName: name)
      return defaults ?? UserDefaults()
    }

    private static func model(_ reader: AppReader, _ defaults: UserDefaults?) -> AppModel {
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      return AppModel(
        reader: reader, now: { AppV2Fixture.now }, stateDefaults: defaults,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
    }

    private func fixture(_ body: (AppReader) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try await body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }

    private func fixture(_ body: (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }
  }
#endif
