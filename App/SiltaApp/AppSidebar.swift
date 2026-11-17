import SiltaAppSupport
import SwiftUI

struct AppSidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      Picker(
        "Workspace",
        selection: Binding(
          get: { model.workspace ?? "" },
          set: { model.selectWorkspace($0) })
      ) {
        ForEach(model.data?.workspaces ?? [], id: \.slug) { workspace in
          Text(workspace.name).tag(workspace.slug)
        }
      }
      .pickerStyle(.menu).padding(12)
      .disabled(model.data?.workspaces.isEmpty != false)
      List {
        Section {
          ForEach(AppRoute.allCases) { route in
            Button {
              model.navigate(to: route)
            } label: {
              HStack {
                Label(route.title, systemImage: route.symbol)
                Spacer()
                Text(count(route), format: .number).font(.caption.monospacedDigit())
              }
            }.buttonStyle(.plain)
              .foregroundStyle(model.route == route ? Color.accentColor : .primary)
          }
        }

        Section("Apps") {
          ForEach(model.visibleData?.map?.apps ?? [], id: \.slug) { app in
            Button {
              model.showApp(app.slug)
            } label: {
              HStack {
                Label(app.slug, systemImage: "square.fill").lineLimit(1)
                Spacer()
                Text(
                  model.visibleData?.snapshot?.board.appOpenCounts[app.slug] ?? 0, format: .number
                )
                .font(.caption.monospacedDigit())
              }
            }.buttonStyle(.plain)
          }
        }
        Section("Claimed now") {
          ForEach(claimed, id: \.ref) { task in
            Button {
              model.inspect(task: task.ref)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 3) {
                  Text(task.ref).font(.caption.monospaced())
                  if !task.steps.isEmpty {
                    Text("Step \(task.steps.filter(\.done).count) of \(task.steps.count)")
                      .font(.caption)
                  }
                  Text(task.claimedBy ?? "").font(.caption2).lineLimit(1)
                }
              } icon: {
                Image(systemName: "terminal").frame(width: 16)
              }
            }.buttonStyle(.plain)
          }
        }
      }.listStyle(.sidebar)
      Divider()
      HStack(spacing: 8) {
        if model.isLoading {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: model.failure == nil ? "checkmark.circle" : "exclamationmark.circle")
        }
        Text(
          model.isLoading ? "Refreshing…" : model.failure == nil ? "Up to date" : "Refresh failed"
        )
        .font(.caption)
        Spacer()
      }.padding(12).accessibilityElement(children: .combine)
    }.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
  }

  private var claimed: [AppTask] {
    model.visibleData?.snapshot?.board.doing.filter { $0.claimedBy != nil } ?? []
  }

  private func count(_ route: AppRoute) -> Int {
    guard let snapshot = model.visibleData?.snapshot else { return 0 }
    switch route {
    case .mywork: return snapshot.work.waitingCount
    case .board:
      return snapshot.board.todo.count + snapshot.board.doing.count + snapshot.board.review.count
    }
  }

}
