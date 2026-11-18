import SiltaAppSupport
import SwiftUI

struct BoardView: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if let snapshot = model.visibleData?.snapshot {
        let content = BoardContent(
          snapshot: snapshot, app: model.appFilter, search: model.search,
          proposals: model.showProposed)
        GeometryReader { geometry in
          let laneWidth = max(180, (geometry.size.width - 28) / 3)
          let open = content.lanes.filter { $0.title != "Done this week" }
          let done = content.lanes.first { $0.title == "Done this week" }
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(open.prefix(2)) { lane in
                ScrollView { laneView(lane, content: content) }.frame(width: laneWidth)
              }
              ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                  ForEach(open.dropFirst(2)) { laneView($0, content: content) }
                  if let done { doneList(done) }
                }
              }.frame(width: laneWidth)
            }.padding(.horizontal, 2).padding(.top, 4)
          }
        }
      }
    }
    .foregroundStyle(Color("Ink"))
    .inspector(isPresented: $model.boardInspectorPresented) {
      TaskInspector(model: model).inspectorColumnWidth(min: 300, ideal: 360, max: 500)
    }
  }

  private func laneView(_ lane: BoardContent.Lane, content: BoardContent) -> some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      laneHeader(lane)
      if lane.tasks.isEmpty {
        Text(model.search.isEmpty ? "No tasks" : "No matches")
          .font(.system(size: 12)).foregroundStyle(Color("ShoreInk")).padding(.vertical)
      }
      ForEach(lane.tasks, id: \.ref) { task in
        card(task, content: content)
      }
    }.padding(.bottom, 8)
  }

  private func laneHeader(_ lane: BoardContent.Lane) -> some View {
    HStack(spacing: 7) {
      if lane.title == "Todo" {
        Circle().strokeBorder(Color("ShoreInk"), lineWidth: 1.5).frame(width: 8, height: 8)
      } else {
        StatusDot(color: laneColor(lane.title))
      }
      Text(lane.title).font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 0)
      Text(lane.tasks.count, format: .number).font(.system(size: 12))
        .foregroundStyle(Color("ShoreInk"))
    }.padding(.horizontal, 4).padding(.bottom, 4).accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
  }

  /// Done tasks read as a compact list: they need a glance, not cards.
  private func doneList(_ lane: BoardContent.Lane) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      laneHeader(lane)
      VStack(alignment: .leading, spacing: 9) {
        if lane.tasks.isEmpty {
          Text(model.search.isEmpty ? "No tasks" : "No matches").font(.system(size: 12))
        }
        ForEach(lane.tasks, id: \.ref) { task in
          let selected = model.boardSelection?.taskRef == task.ref
          Button {
            model.inspect(task: task.ref)
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(task.ref).font(.system(size: 11, design: .monospaced))
              Text(task.title).font(.system(size: 13)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(Color(selected ? "TideText" : "SecondaryInk")).contentShape(.rect)
          }.buttonStyle(.plain).help(task.title)
            .accessibilityLabel(task.ref + ": " + task.title + ", done")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }.padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading).seaPane(radius: 12)
    }
  }

  private func card(_ task: AppTask, content: BoardContent) -> some View {
    let asked = content.questions.contains(task.ref)
    let done = task.status == "done"
    let selected = model.boardSelection?.taskRef == task.ref
    return Button {
      model.inspect(task: task.ref)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          Text([task.ref, task.app].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced)).lineLimit(1)
            .foregroundStyle(Color("SecondaryInk"))
            .help([task.ref, task.app].compactMap { $0 }.joined(separator: " · "))
          if asked {
            Circle().fill(Color("AttentionMarker")).frame(width: 7, height: 7).help("Asked you")
          }
        }
        Text(task.title).font(.system(size: 14, weight: selected ? .semibold : .medium))
          .foregroundStyle(Color(done ? "SecondaryInk" : "Ink"))
          .lineLimit(3).lineSpacing(2).help(task.title)
        if task.status == "blocked" || task.status == "proposed" {
          Label(
            task.status.capitalized,
            systemImage: task.status == "blocked" ? "pause.circle" : "sparkle"
          )
          .font(.system(size: 11)).foregroundStyle(Color("Warning"))
        }
        if task.status == "doing", !task.steps.isEmpty {
          TaskStepBar(steps: task.steps)
        }
        if let now = model.visibleData?.checkedAt,
          let metadata = TaskPresentation.cardMetadata(
            task, asked: asked, questionAuthor: content.questionAuthor(for: task.ref), now: now)
        {
          Text(metadata).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
            .lineLimit(2).help(metadata)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(
        .vertical, 12
      )
      .modifier(BoardCardSurface(task: task, selected: selected))
    }.buttonStyle(.plain).accessibilityElement(children: .ignore)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityLabel(
        task.ref + ": " + task.title + ", " + task.status
          + (asked ? ", asked you" : "")
          + (task.steps.isEmpty
            ? "" : ", " + TaskPresentation.progress(task.steps, revision: task.planRevision)))
  }

  private func laneColor(_ title: String) -> Color {
    switch title {
    case "Doing": Color("TideText")
    case "Review": Color("Warning")
    case "Done this week": Color("Success")
    default: Color("SecondaryInk")
    }
  }
}

private struct TaskStepBar: View {
  let steps: [AppPlanStep]
  var body: some View {
    HStack(spacing: 3) {
      ForEach(steps.indices, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2)
          .fill(steps[index].done ? Color("TideText") : Color("Ink").opacity(0.12))
      }
    }.frame(height: 3).padding(.vertical, 2).accessibilityHidden(true)
  }
}

private struct BoardCardSurface: ViewModifier {
  let task: AppTask
  let selected: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .background(
        reduceTransparency ? Color("Canvas") : Color(task.status == "done" ? "Pane" : "Card"),
        in: .rect(cornerRadius: 14, style: .continuous)
      )
      .overlay(cardBorder(task, selected: selected))
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(Color("AccentColor").opacity(0.14)).padding(-3)
        }
      }
  }

  private func cardBorder(_ task: AppTask, selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
      selected
        ? Color("AccentColor")
        : task.status == "proposed" ? Color("Warning") : Color("PaneBorder"),
      style: StrokeStyle(
        lineWidth: selected ? 2 : 1, dash: task.status == "proposed" ? [4, 3] : []))
  }

}
