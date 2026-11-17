import AppKit
import Foundation
import SiltaAppSupport
import SwiftUI

struct MyWorkView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if let work = model.visibleData?.snapshot?.work {
          if work.waitingCount == 0 && model.search.isEmpty {
            ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle")
              .frame(maxWidth: .infinity).padding(.top, 80)
          }
          if !model.search.isEmpty && !model.hasWorkMatches {
            ContentUnavailableView(
              "No matches", systemImage: "magnifyingglass",
              description: Text("Try a different reference or search term."))
          }
          let attentionItems = work.items.filter { $0.kind != "proposal" }
          ForEach(attentionItems, id: \.stableID) { item in
            if model.matches(item) {
              attention(item)
              Divider().padding(.vertical, 24)
            }
          }
          ForEach(work.reviews, id: \.ref) { task in
            if matches([task.ref, task.title, task.description]) {
              VStack(alignment: .leading, spacing: 12) {
                heading("Ready for review", ref: task.ref)
                Text(task.title).font(.title3.weight(.semibold))
                Text(task.claimedBy ?? task.createdBy).font(.callout).foregroundStyle(.secondary)
                commands(model.reader?.commands(forReview: task, workspace: workspace) ?? [])
              }
              Divider().padding(.vertical, 24)
            }
          }
          let proposals = model.proposals
          if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
              Text("Proposed tasks · \(proposals.count)").font(.headline)
              ForEach(proposals, id: \.stableID) { item in
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? "Proposed task").font(.body.weight(.medium))
                    if let author = item.author {
                      Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  ForEach(item.refs, id: \.self) { ref in reference(ref) }
                }
              }
              if let first = proposals.first {
                commands(
                  Array((model.reader?.commands(for: first, workspace: workspace) ?? []).prefix(2)))
              }
            }
            Divider().padding(.vertical, 24)
          }
          if work.remaining > 0 {
            Text("\(work.remaining) more waiting items").font(.headline)
            if let command = model.reader?.inboxCommand(workspace: workspace) {
              commands([command])
            }
          }
        }
      }.padding(32).frame(maxWidth: 1000, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var workspace: String { model.workspace ?? "" }

  private func matches(_ values: [String]) -> Bool { model.matches(values) }

  private func attention(_ item: AppAttention) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      heading(title(item), ref: item.ref ?? item.task)
      if item.kind == "doc_proposal", let ref = item.refs.first {
        Button("Open in Docs") { model.openDocument(ref) }
      }
      if let title = item.title { Text(title).font(.title3.weight(.semibold)) }
      if let body = item.body { Text(body).font(.body).textSelection(.enabled) }
      if let author = item.author {
        Text(author).font(.callout).foregroundStyle(.secondary)
      }
      if item.refs.count > 1 {
        HStack { ForEach(item.refs, id: \.self) { ref in reference(ref) } }
      }
      commands(model.reader?.commands(for: item, workspace: workspace) ?? [])
    }
  }

  private func title(_ item: AppAttention) -> String {
    switch item.kind {
    case "question": "A question for you"
    case "proposal": "Proposed tasks"
    case "answer": "An answer to accept"
    case "doc_proposal": "Document proposals"
    default: item.kind.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }

  private func heading(_ title: String, ref: String?) -> some View {
    HStack {
      Text(title).font(.headline)
      Spacer()
      if let ref { reference(ref) }
    }
  }

  private func reference(_ ref: String) -> some View {
    CopyValue(value: ref, title: "Copy reference")

  }

  private func commands(_ values: [AppCommand]) -> some View {
    ForEach(values, id: \.text) { command in CommandBlock(command: command) }
  }

}

struct CopyValue: View {
  let value: String
  let title: String
  var compact = false
  @State private var copied = false

  var body: some View {
    Button {
      copy()
    } label: {
      Label(
        compact ? (copied ? "Copied" : title) : value,
        systemImage: copied ? "checkmark" : "doc.on.doc"
      )
      .font(.system(.caption, design: .monospaced))
    }.buttonStyle(.bordered).labelStyle(.titleAndIcon)
      .help(title).accessibilityLabel(title + ": " + value)
      .contextMenu { Button(title) { copy() } }
      .onCopyCommand { [NSItemProvider(object: value as NSString)] }
      .onChange(of: value) { copied = false }
      .task(id: copied) {
        guard copied else { return }
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        copied = false
      }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    copied = NSPasteboard.general.setString(value, forType: .string)
  }

}
