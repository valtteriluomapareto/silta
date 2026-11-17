import AppKit
import Combine
import Foundation
import SwiftUI
import SiltaAppSupport

struct AppShellView: View {
  @Bindable var model: AppModel
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
      }.background(Color(nsColor: .textBackgroundColor))
    }
    .navigationTitle(model.route.title)
    .navigationSubtitle(subtitle)
    .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh(force: true) }
          .labelStyle(.iconOnly).help("Refresh (⌘R)")
      }
    }
    .frame(minWidth: 1000, minHeight: 700)
    .task { await model.refresh().value }
    .task(id: phase) { await foregroundChecks() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.focused()
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
      }
    }
  }

  private var subtitle: String {
    guard let data = model.visibleData else { return "" }
    if model.route == .board, let board = data.snapshot?.board {
      return "\(board.todo.count + board.doing.count + board.review.count) open · "
        + "\(board.proposedCount) proposed · \(board.doneThisWeek.count) done this week"
    }
    let claimed = data.snapshot?.board.doing.filter { $0.claimedBy != nil }.count ?? 0
    return "\(data.snapshot?.work.waitingCount ?? 0) waiting on you · \(claimed) tasks claimed"
  }

  private func foregroundChecks() async {
    guard phase == .active else { return }
    await model.focused().value
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard !Task.isCancelled else { return }
      await model.tick(frontmost: true)?.value
    }
  }
}
