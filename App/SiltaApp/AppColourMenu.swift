import AppKit
import SwiftUI

/// Chooses an app's colour from the palette; the choice stays on this Mac. A picker gives
/// the menu native checkmarks, and Automatic names the colour it stands for.
struct AppColourMenu: View {
  @Bindable var model: AppModel
  let slug: String

  var body: some View {
    Picker("Colour", selection: choice) {
      Label {
        Text("Automatic (" + AppPalette.title(AppPalette.automatic(slug)) + ")")
      } icon: {
        Image(nsImage: Self.swatch(AppPalette.automatic(slug)))
      }.tag(String?.none)
      Divider()
      ForEach(AppPalette.colours, id: \.self) { colour in
        Label {
          Text(AppPalette.title(colour))
        } icon: {
          Image(nsImage: Self.swatch(colour))
        }.tag(String?.some(colour))
      }
    }.pickerStyle(.menu)
      .accessibilityValue(Self.spoken(model: model, slug: slug))
  }

  private var choice: Binding<String?> {
    Binding(
      get: { model.chosenAppColours[slug] },
      set: { model.setAppColour($0, for: slug) })
  }

  /// What VoiceOver says for the current colour, such as "Blue, automatic".
  static func spoken(model: AppModel, slug: String) -> String {
    AppPalette.title(model.appColour(slug))
      + (model.chosenAppColours[slug] == nil ? ", automatic" : ", chosen")
  }

  /// A rounded colour square for the menu; menus drop SwiftUI tints on symbols.
  private static func swatch(_ colour: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      (NSColor(named: colour) ?? .gray).setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).fill()
      return true
    }
    image.isTemplate = false
    return image
  }
}
