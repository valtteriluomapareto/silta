#if DEBUG
  import AppKit
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct AppColourTests {
    @Test func paletteHasEightDistinctAssetColours() throws {
      #expect(
        AppPalette.colours == [
          "AppIndigo", "AppBlue", "AppViolet", "AppPlum", "AppRose", "AppClay", "AppBrown",
          "AppSlate",
        ])
      #expect(AppPalette.colours.map(AppPalette.title) == [
        "Indigo", "Blue", "Violet", "Plum", "Rose", "Clay", "Brown", "Slate",
      ])
      for name in AppPalette.colours { #expect(NSColor(named: name) != nil, "\(name)") }
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func everyColourReadsAsTextOnACard(appearance: String) throws {
      let look = try #require(NSAppearance(named: NSAppearance.Name(appearance)))
      var card = NSColor.white
      look.performAsCurrentDrawingAppearance {
        card = NSColor(named: "Card")?.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? .white
      }
      for name in AppPalette.colours {
        var colour = NSColor.black
        look.performAsCurrentDrawingAppearance {
          colour = NSColor(named: name)?.usingColorSpace(.sRGB) ?? .black
        }
        #expect(Self.contrast(colour, card) >= 4.5, "\(name) \(appearance)")
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
      #expect(Set(slugs.map(AppPalette.automatic)).count == 3)
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

        let relaunched = Self.model(reader, defaults)
        await relaunched.refresh().value
        #expect(relaunched.appColour("acme-web") == chosen)
        relaunched.setAppColour(nil, for: "acme-web")
        #expect(relaunched.appColour("acme-web") == automatic)
        #expect(Self.model(reader, defaults).chosenAppColours.isEmpty)

        let automated = Self.model(reader, nil)
        automated.setAppColour(chosen, for: "acme-mobile")
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
        let board = BoardContent(
          snapshot: snapshot, apps: apps, filter: BoardFilter(), search: "", colours: chosen)
        let web = try #require(snapshot.board.todo.first { $0.app == "acme-web" })
        #expect(board.appLabel(for: web)?.color == "AppRose")
      }
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
      return defaults ?? .standard
    }

    private static func model(_ reader: AppReader, _ defaults: UserDefaults?) -> AppModel {
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      return AppModel(
        reader: reader, now: { AppV2Fixture.now }, defaults: defaults,
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
