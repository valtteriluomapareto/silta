import AppKit

/// The human's choice of light or dark, or following the system, stored in defaults.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system, light, dark

  /// The defaults key the View menu and Settings share.
  static let storageKey = "appearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// The app-wide AppKit appearance; nil follows the system. Applying it to
  /// `NSApplication` reaches the toolbar, sidebar glass and every window.
  var appearanceName: NSAppearance.Name? {
    switch self {
    case .system: nil
    case .light: .aqua
    case .dark: .darkAqua
    }
  }
}
