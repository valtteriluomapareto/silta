import AppKit
import Combine
import Foundation
import SiltaAppSupport
import SwiftUI

struct AppShellView: View {
  @Bindable var model: AppModel
  @FocusState private var searchFocused: Bool
  @Environment(\.scenePhase) private var phase

  var body: some View {
    NavigationSplitView {
      AppSidebar(model: model)
    } detail: {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(model.route.title).font(.system(size: 15, weight: .bold))
            Text(model.screenSummary).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
          }.frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
            TextField(
              model.route == .docs ? "Search loaded documents" : "Search", text: $model.search
            )
            .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
            .accessibilityLabel("Search")
          }.padding(.horizontal, 12).frame(width: 220, height: 32)
            .background(Color.primary.opacity(0.05), in: Capsule())
          Button("Refresh", systemImage: "arrow.clockwise") { model.refresh(force: true) }
            .labelStyle(.iconOnly).buttonStyle(.plain).help("Refresh (⌘R)")
        }.frame(height: 56).padding(.horizontal, 16)
        if let failure = model.failure, model.visibleData != nil {
          Label(failure.message, systemImage: "exclamationmark.triangle")
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
          Divider()
        }
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Color("Canvas"))
    }
    .navigationTitle("Silta")
    .focusedSceneValue(\.findAction, { searchFocused = true })
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
