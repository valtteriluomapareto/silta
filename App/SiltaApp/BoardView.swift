import SiltaAppSupport
import SwiftUI

struct BoardView: View {
  @Bindable var model: AppModel
  @State private var showProposals = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Picker("App", selection: $model.appFilter) {
          Text("All apps").tag(String?.none)
          ForEach(model.visibleData?.map?.apps ?? [], id: \.slug) { app in
            Text(app.name).tag(Optional(app.slug))
          }
        }.frame(maxWidth: 250)
        Toggle("Show proposed", isOn: $showProposals).toggleStyle(.checkbox)
        Spacer()
        Button("Inspector", systemImage: "sidebar.right") { model.inspectorPresented.toggle() }
          .labelStyle(.iconOnly).help("Toggle inspector (⌥⌘I)")
      }.padding(.horizontal, 24).padding(.top, 16)
      if let snapshot = model.visibleData?.snapshot {
        let content = BoardContent(
          snapshot: snapshot, app: model.appFilter, search: model.search, proposals: showProposals)
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(content.lanes) { lane in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Text(lane.title).font(.headline)
                    Spacer()
                    Text(lane.tasks.count, format: .number).foregroundStyle(.secondary)
                  }.padding(.bottom, 4)
                  if lane.tasks.isEmpty {
                    Text("No tasks").font(.callout).foregroundStyle(.secondary).padding(.vertical)
                  }
                  ForEach(lane.tasks, id: \.ref) { task in
                    card(task, asked: content.questions.contains(task.ref))
                  }
                }.padding(.bottom, 24)
              }.frame(width: 210)
            }
          }.padding(.horizontal, 24)
        }
      }
    }
    .inspector(isPresented: $model.inspectorPresented) {
      TaskInspector(model: model).inspectorColumnWidth(min: 300, ideal: 360, max: 500)
    }
  }

  private func card(_ task: AppTask, asked: Bool) -> some View {
    Button {
      model.inspect(task.ref)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text([task.ref, task.app].compactMap { $0 }.joined(separator: " · "))
          .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        Text(task.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        if task.status == "blocked" || task.status == "proposed" {
          Label(
            task.status.capitalized,
            systemImage: task.status == "blocked" ? "pause.circle" : "sparkle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if task.status == "doing", !task.steps.isEmpty {
          ProgressView(
            value: Double(task.steps.filter(\.done).count), total: Double(task.steps.count))
          Text("Step \(task.steps.filter(\.done).count) of \(task.steps.count)")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let actor = task.claimedBy { Text(actor).font(.caption).foregroundStyle(.secondary) }
        if asked {
          Label("Asked you", systemImage: "questionmark.circle.fill").font(.caption)
            .foregroundStyle(.tint)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
          RoundedRectangle(cornerRadius: 9).stroke(
            model.selectedTask == task.ref ? Color.accentColor : Color.secondary.opacity(0.25),
            lineWidth: model.selectedTask == task.ref ? 2 : 1))
    }.buttonStyle(.plain).accessibilityElement(children: .ignore)
      .accessibilityLabel(task.ref + ": " + task.title + ", " + task.status)
  }
}
