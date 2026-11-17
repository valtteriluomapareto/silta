nonisolated enum AppRoute: String, CaseIterable, Identifiable {
  case mywork, board, workspace, docs
  var id: String { rawValue }
  var title: String {
    switch self {
    case .mywork: "My work"
    case .board: "Board"
    case .workspace: "Workspace"
    case .docs: "Docs"
    }
  }
  var symbol: String {
    switch self {
    case .mywork: "tray"
    case .board: "square.grid.2x2"
    case .workspace: "network"
    case .docs: "doc.text"
    }
  }
}
