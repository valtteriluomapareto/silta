nonisolated enum AppRoute: String, CaseIterable, Identifiable {
  case mywork, board, workspace
  var id: String { rawValue }
  var title: String {
    switch self {
    case .mywork: "My work"
    case .board: "Board"
    case .workspace: "Workspace"
    }
  }
  var symbol: String {
    switch self {
    case .mywork: "tray"
    case .board: "square.grid.2x2"
    case .workspace: "network"
    }
  }
}
