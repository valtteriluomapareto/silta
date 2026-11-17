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
          HStack {
            Label("My work", systemImage: "tray")
            Spacer()
            Text(model.visibleData?.snapshot?.work.waitingCount ?? 0, format: .number)
              .font(.caption.monospacedDigit())
          }.foregroundStyle(Color.accentColor)
        }

        Section("Apps") {
          ForEach(model.visibleData?.map?.apps ?? [], id: \.slug) { app in
            HStack {
              Label(app.slug, systemImage: "square.fill").lineLimit(1)
              Spacer()
              Text(model.visibleData?.snapshot?.board.appOpenCounts[app.slug] ?? 0, format: .number)
                .font(.caption.monospacedDigit())
            }
          }
        }
        Section("Claimed now") {
          ForEach(claimed, id: \.ref) { task in
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

}
