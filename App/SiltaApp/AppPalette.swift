/// App identity colours: eight hues apart from the status colours (Success, Warning,
/// AttentionMarker, TideText), each with a light and dark asset that reads as text on a
/// card. An app keeps an automatic colour from its slug unless the human chooses one.
nonisolated enum AppPalette {
  static let colours = [
    "AppIndigo", "AppBlue", "AppViolet", "AppPlum", "AppRose", "AppClay", "AppBrown", "AppSlate",
  ]

  /// The colour's menu name, such as `Indigo`.
  static func title(_ colour: String) -> String {
    colour.hasPrefix("App") ? String(colour.dropFirst(3)) : colour
  }

  /// A colour picked from the slug alone, so adding or reordering apps never recolours
  /// another. FNV-1a over UTF-8 is stable across launches, unlike `hashValue`; folding
  /// the high half in spreads similar slugs, whose low bits cluster.
  static func automatic(_ slug: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in slug.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    return colours[Int(((hash >> 16) ^ hash) % UInt32(colours.count))]
  }
}
