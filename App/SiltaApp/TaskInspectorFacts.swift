import SiltaAppSupport
import SwiftUI

/// What a blocked task waits on: each blocker, the reason, and when Unblock is offered.
struct WaitingSection: View {
  let waiting: TaskFacts.Waiting

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Overline(waiting.heading)
        Spacer(minLength: 8)
        if let followUp = waiting.followUp {
          Text(followUp).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
        }
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(waiting.blockers.enumerated()), id: \.offset) { index, blocker in
          if index > 0 { Divider() }
          row(blocker)
        }
        if !waiting.blockers.isEmpty { Divider() }
        Text(waiting.why).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.vertical, 9)
      }
      .background(Color("Card"), in: .rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color("Ink").opacity(0.08)))
      Text(waiting.footer).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func row(_ blocker: TaskFacts.Blocker) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol(blocker.state)).foregroundStyle(tint(blocker.state))
        .accessibilityLabel(label(blocker.state))
      Text(blocker.ref).font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color("TideText")).textSelection(.enabled)
      if let detail = blocker.detail {
        Text(detail).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, 12).padding(.vertical, 9).accessibilityElement(children: .combine)
  }

  private func symbol(_ state: AppBlocker.State) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .open: "pause.circle"
    case .dropped: "xmark.circle"
    }
  }

  private func tint(_ state: AppBlocker.State) -> Color {
    Color(state == .done ? "Success" : "Warning")
  }

  private func label(_ state: AppBlocker.State) -> String {
    switch state {
    case .done: "Done"
    case .open: "Open"
    case .dropped: "Dropped"
    }
  }
}

/// A completed or dropped task's result, its Friction line and completion facts.
struct ResultSection: View {
  let result: (body: String, friction: String?)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Overline("Result")
      if !result.body.isEmpty { DocumentMarkdown(result.body) }
      if let friction = result.friction {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Friction").font(.system(size: 12, weight: .semibold))
          Text(friction).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color("Ink").opacity(0.04), in: .rect(cornerRadius: 8))
      }
    }
  }
}

/// A released claim, so the next agent resumes from the handoff.
struct HandoffNote: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "arrow.uturn.forward.circle")
      .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color("TideText"))
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color("TideText").opacity(0.07), in: .rect(cornerRadius: 12))
  }
}

/// Related tasks or links listed by reference, each with a short title.
struct ReferenceList: View {
  struct Row {
    let ref: String
    let text: String
    var url: URL?
  }

  let title: String
  let rows: [Row]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Overline(title)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.ref).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color("TideText")).textSelection(.enabled)
          if let url = row.url {
            Link(row.text, destination: url).font(.system(size: 12)).lineLimit(1)
              .foregroundStyle(Color("TideText"))
              .truncationMode(.middle)
          } else {
            Text(row.text).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }
}
