import AppKit
import Combine
import Foundation
import SiltaAppSupport
import SwiftUI

struct AppShellView: View {
  @Bindable var model: AppModel
  @State private var searchFocused = false
  @State private var windowWidth: CGFloat = 1280
  @Environment(\.scenePhase) private var phase

  var body: some View {
    NavigationSplitView {
      AppSidebar(model: model)
    } detail: {
      VStack(spacing: 0) {
        if let failure = model.failure, model.visibleData != nil {
          Label(failure.message, systemImage: "exclamationmark.triangle")
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
          Divider()
        }
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Color("Canvas"))
    }
    .navigationTitle(model.screenTitle)
    .navigationSubtitle(model.screenSummary)
    .focusedSceneValue(\.findAction, { searchFocused = true })
    .toolbar {
      AppScreenToolbar(
        model: model, searchFocused: $searchFocused,
        compactSearch: model.route == .docs && windowWidth < 1200)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      windowWidth = $0
    }
    .frame(minWidth: 1000, minHeight: 700)
    .task { await model.refresh().value }
    .task(id: phase) { await foregroundChecks() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refresh()
    }
  }

  @ViewBuilder private var content: some View {
    if model.visibleData == nil, model.isLoading {
      ProgressView("Loading Silta…")
    } else if let failure = model.failure, model.visibleData == nil {
      ContentUnavailableView {
        Label(
          failure.kind == .newerSchema ? "Update Silta" : "Silta data unavailable",
          systemImage: "externaldrive.badge.exclamationmark")
      } description: {
        Text(failure.message)
      } actions: {
        ForEach(failure.commands, id: \.self) { command in
          Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
        Button("Refresh") { model.refresh(force: true) }
      }
    } else if model.visibleData?.workspaces.isEmpty == true {
      ContentUnavailableView(
        "No workspaces yet", systemImage: "square.stack",
        description: Text("Create a workspace with the Silta CLI, then refresh."))
    } else {
      switch model.route {
      case .mywork: MyWorkView(model: model)
      case .board: BoardView(model: model)
      case .workspace: WorkspaceView(model: model)
      case .docs: DocsView(model: model)
      }
    }
  }

  private func foregroundChecks() async {
    guard phase == .active else { return }
    await model.refresh().value
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard !Task.isCancelled else { return }
      await model.tick(frontmost: NSApplication.shared.isActive)?.value
    }
  }
}
