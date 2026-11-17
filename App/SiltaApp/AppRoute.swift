nonisolated enum AppRoute: String, CaseIterable, Identifiable {
  case mywork, board
  var id: String { rawValue }
  var title: String { self == .mywork ? "My work" : "Board" }
  var symbol: String { self == .mywork ? "tray" : "square.grid.2x2" }
}
