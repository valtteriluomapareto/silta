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
          let laneWidth = max(144, (geometry.size.width - 78) / 4)
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
              ForEach(content.lanes) { lane in
                ScrollView {
                  LazyVStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                      if lane.title == "Todo" {
                        Circle().strokeBorder(Color("SecondaryInk"), lineWidth: 1.5).frame(
                          width: 8, height: 8)
                      } else {
                        StatusDot(color: laneColor(lane.title))
                      }
                      Text(lane.title).font(.system(size: 13, weight: .semibold))
                      Spacer(minLength: 0)
                      Text(lane.tasks.count, format: .number).font(.system(size: 12))
                        .foregroundStyle(Color("SecondaryInk"))
                    }.padding(.bottom, 4)
                    if lane.tasks.isEmpty {
                      Text(model.search.isEmpty ? "No tasks" : "No matches")
                        .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk")).padding(
                          .vertical)
                    }
                    ForEach(lane.tasks, id: \.ref) { task in
                      card(task, content: content)
                    }
                  }.padding(.bottom, 24)
                }.frame(width: laneWidth)
              }
            }.padding(.horizontal, 24).padding(.top, 16)
          }
        }
      }
    }
    .foregroundStyle(Color("Ink"))
    .inspector(isPresented: $model.boardInspectorPresented) {
      TaskInspector(model: model).inspectorColumnWidth(min: 300, ideal: 360, max: 500)
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
        Text(task.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
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
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(
        .vertical, 10
      )
      .background(Color(done ? "CommandSurface" : "Canvas"), in: .rect(cornerRadius: 10))
      .overlay(cardBorder(task, selected: selected))
    }.buttonStyle(.plain).accessibilityElement(children: .ignore)
      .accessibilityLabel(
        task.ref + ": " + task.title + ", " + task.status
          + (asked ? ", asked you" : "")
          + (task.steps.isEmpty
            ? "" : ", " + TaskPresentation.progress(task.steps, revision: task.planRevision)))
  }

  private func cardBorder(_ task: AppTask, selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 10).strokeBorder(
      selected
        ? Color("TideText")
        : task.status == "proposed" ? Color("Warning") : Color("Ink").opacity(0.12),
      style: StrokeStyle(
        lineWidth: selected ? 1.5 : 1, dash: task.status == "proposed" ? [4, 3] : []))
  }

  private func laneColor(_ title: String) -> Color {
    switch title {
    case "Doing": Color("TideText")
    case "Review": Color("Warning")
    case "Done this week": Color("DiffAddition")
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
