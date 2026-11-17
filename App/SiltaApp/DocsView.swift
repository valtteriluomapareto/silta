import SiltaAppSupport
import SwiftUI

struct DocsView: View {
  @Bindable var model: AppModel
  @State private var docs = DocsModel()
  @State private var archived = false

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Include archived", isOn: $archived).toggleStyle(.checkbox).padding(.horizontal)
        if let about = model.docsAbout {
          HStack {
            Text(about).font(.caption).lineLimit(2)
            Button("Clear filter") { model.docsAbout = nil }
          }.padding(.horizontal)
        }
        List {
          ForEach(docs.groups(search: model.search)) { group in
            if let preferred = group.preferred {
              Button {
                docs.ref = preferred.ref
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  Text(preferred.title ?? preferred.slug).font(.body.weight(.medium))
                  Text(
                    "@\(preferred.revision) · \(preferred.state)"
                      + (preferred.archived ? " · archived" : "")
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  let pending = group.entries.filter { $0.state == "proposed" }.count
                  if pending > 0 {
                    Text("\(pending) proposed").font(.caption).foregroundStyle(.secondary)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain)
                .listRowBackground(
                  docs.document?.slug == group.id ? Color.accentColor.opacity(0.15) : .clear)
            }
          }
          if docs.nextList != nil {
            Button("Load more documents") { Task { await refresh(append: true) } }
          }
        }
        if let error = docs.listFailure {
          Text(error).font(.caption).padding(.horizontal)
          Button("Retry list") { Task { await refresh() } }
        }
      }.padding(.top, 16).frame(minWidth: 230, idealWidth: 280, maxWidth: 380)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let document = docs.document {
            HStack {
              Text(document.title ?? document.slug).font(.title2.weight(.semibold))
              Spacer()
              CopyValue(value: document.ref, title: "Copy document reference")
            }
            Text(document.state.capitalized + (document.archived ? " · Archived" : ""))
              .font(.callout).foregroundStyle(.secondary)
            HStack {
              Picker("Revision", selection: $docs.ref) {
                if !docs.versions.contains(where: { $0.ref == document.ref }) {
                  Text("@\(document.revision) · \(document.state)").tag(Optional(document.ref))
                }
                ForEach(docs.versions, id: \.ref) { version in
                  Text("@\(version.revision) · \(version.state)").tag(Optional(version.ref))
                }
              }.frame(maxWidth: 300)
              if docs.nextVersions != nil, let reader = model.reader,
                let workspace = model.workspace
              {
                Button("Older revisions") {
                  Task { await docs.moreVersions(reader, workspace: workspace) }
                }
              }
            }
            if let kind = document.kind { Text(kind).font(.caption).foregroundStyle(.secondary) }
            if let about = document.about {
              ForEach(Array(about.enumerated()), id: \.offset) { _, ref in
                CopyValue(value: ref, title: "Copy attachment reference")
              }
            } else {
              Text("Attachments not recorded").font(.caption).foregroundStyle(.secondary)
            }
          }
          Picker("View", selection: $docs.view) {
            ForEach(AppDocumentView.allCases, id: \.self) { view in
              Text(view.rawValue.capitalized).tag(view)
            }
          }.pickerStyle(.segmented)
          if let error = docs.failure {
            Text(error).foregroundStyle(.secondary)
            Button("Retry") { Task { await show() } }
          }
          if docs.loading { ProgressView("Loading document…") }
          if docs.ref == nil {
            ContentUnavailableView("Select a document", systemImage: "doc.text")
          } else if docs.view == .comments {
            if docs.comments.isEmpty && !docs.loading {
              Text("No comments yet").foregroundStyle(.secondary)
            }
            ForEach(docs.comments, id: \.ref) { comment in
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Text(comment.actor + " · " + comment.kind).font(.caption).foregroundStyle(
                    .secondary)
                  Spacer()
                  CopyValue(value: comment.ref, title: "Copy comment reference")
                }
                DocumentMarkdown(comment.body).textSelection(.enabled)
                Divider()
              }
            }
            if docs.nextComments != nil, let reader = model.reader, let workspace = model.workspace
            {
              Button("Load more comments") {
                Task { await docs.moreComments(reader, workspace: workspace) }
              }
            }
          } else {
            if docs.view == .document {
              DocumentMarkdown(docs.body.isEmpty ? docs.text : docs.body).textSelection(.enabled)
            } else {
              Text(docs.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if docs.nextLine != nil {
              Button("Load more") { Task { await show(append: true) } }.disabled(docs.loading)
            }
          }
          if let document = docs.document, let reader = model.reader,
            let workspace = model.workspace
          {
            let commands = reader.commands(
              forDocument: document, workspace: workspace, view: docs.view)
            ForEach(commands, id: \.text) { command in CommandBlock(command: command) }
          }
        }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(
          maxWidth: .infinity, alignment: .leading)
      }.frame(minWidth: 400)
    }
    .task(id: listKey) { await refresh() }
    .task(id: detailKey) { await show() }
  }

  private var listKey: String {
    "\(model.workspace ?? "")|\(model.docsAbout ?? "")|\(archived)|\(model.visibleData?.version ?? 0)"
  }
  private var detailKey: String {
    "\(model.workspace ?? "")|\(docs.ref ?? "")|\(docs.view.rawValue)|\(model.visibleData?.version ?? 0)"
  }
  private func refresh(append: Bool = false) async {
    guard let reader = model.reader, let workspace = model.workspace else { return }
    await docs.refresh(
      reader, workspace: workspace, about: model.docsAbout, archived: archived, append: append)
    if let requested = model.docsRequestedRef {
      docs.ref = requested
      model.docsRequestedRef = nil
    } else if docs.ref == nil {
      docs.ref = docs.groups(search: "").first?.preferred?.ref
    }
  }
  private func show(append: Bool = false) async {
    guard let reader = model.reader, let workspace = model.workspace else { return }
    await docs.show(reader, workspace: workspace, append: append)
  }
}
