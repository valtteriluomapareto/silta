import SiltaAppSupport
import SwiftUI

struct DocsView: View {
  @Bindable var model: AppModel
  private var docs: DocsModel { model.documents }
  private var phase: DocsModel.Phase {
    docs.phase(
      workspace: model.workspace, about: model.docsAbout,
      archived: model.includeArchivedDocuments, version: model.visibleData?.version)
  }

  var body: some View {
    HSplitView {
      documentList.frame(minWidth: 230, idealWidth: 270, maxWidth: 280)
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if let banner = DocsChromeContent.banner(
              document: docs.document, revisions: docs.versions, partial: docs.nextVersions != nil,
              now: model.now())
            {
              proposalBanner(banner)
            }
            if let document = docs.document {
              HStack(alignment: .firstTextBaseline) {
                Text(document.title ?? document.slug).font(.system(size: 24, weight: .bold))
                Spacer(minLength: 12)
                CopyValue(
                  value: document.ref, title: "Copy document reference",
                  warning: document.state == "proposed")
              }
              if let now = model.visibleData?.checkedAt {
                Text(DocsContent.attribution(document, now: now))
                  .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
              }
              if let about = document.about, !about.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("About").font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
                  ViewThatFits {
                    HStack { ForEach(about, id: \.self) { attachment($0) } }
                    VStack(alignment: .leading) { ForEach(about, id: \.self) { attachment($0) } }
                  }
                }
              } else if document.about == nil {
                Text("Attachments not recorded").font(.system(size: 12))
                  .foregroundStyle(Color("SecondaryInk"))
              }
            }
            if let error = docs.failure {
              Text(error).foregroundStyle(Color("SecondaryInk"))
              Button("Retry") { Task { await show(force: true) } }
            }
            if phase == .loading { ProgressView("Loading document…") }
            if docs.ref == nil && phase == .ready {
              ContentUnavailableView("Select a document", systemImage: "doc.text")
            } else if docs.view == .comments {
              comments
            } else if docs.view == .changes {
              diff
            } else if docs.showingSource {
              ScrollView(.horizontal) {
                Text(DocsContent.readerText(docs.document, body: docs.body, diagnostic: docs.text))
                  .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
              }
            } else {
              DocumentMarkdown(
                DocsContent.readerText(docs.document, body: docs.body, diagnostic: docs.text),
                title: docs.document?.title)
            }
            if docs.nextLine != nil, docs.view != .comments {
              Button("Load more") { Task { await show(append: true) } }.disabled(docs.loading)
            }
            Spacer(minLength: 24)
            if docs.document != nil { footer }
          }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.frame(minWidth: 400)
    }
    .foregroundStyle(Color("Ink"))
    .task(id: listKey) { await model.loadDocuments() }
    .task(id: detailKey) { await show() }
  }

}

extension DocsView {
  private var documentList: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(
        "Documents", selection: Binding(get: { docs.proposedOnly }, set: { docs.proposedOnly = $0 })
      ) {
        Text("All").tag(false)
        Text(docs.proposedLabel).tag(true)
      }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)
      if let about = model.docsAbout {
        HStack(spacing: 6) {
          Text(DocsChromeContent.aboutLabel(about)).font(.system(size: 11)).lineLimit(2).help(about)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Clear filter", systemImage: "xmark") { model.docsAbout = nil }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }.padding(8).foregroundStyle(Color("TideText"))
          .background(Color("TideText").opacity(0.08), in: .rect(cornerRadius: 8))
          .padding(.horizontal, 12)
      }
      if docs.listLoading { ProgressView("Loading documents…").padding(.horizontal, 12) }
      List {
        ForEach(DocsContent.sections(docs.groups(search: model.search))) { section in
          Section {
            ForEach(section.groups) { group in
              if let preferred = group.preferred {
                Button {
                  model.select(document: preferred.ref)
                } label: {
                  HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text").frame(width: 16).foregroundStyle(
                      Color("SecondaryInk"))
                    VStack(alignment: .leading, spacing: 4) {
                      Text(preferred.title ?? preferred.slug).font(
                        .system(size: 13, weight: .medium)
                      ).foregroundStyle(Color(preferred.archived ? "SecondaryInk" : "Ink"))
                      Text(DocsContent.row(group)).font(.system(size: 11)).foregroundStyle(
                        Color(preferred.archived ? "SecondaryInk" : "TideText"))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                  }.padding(.vertical, 5).contentShape(.rect)
                }.buttonStyle(.plain)
                  .listRowSeparator(.hidden)
                  .listRowBackground(
                    docs.document?.slug == group.id ? Color("TideText").opacity(0.12) : .clear)
              }
            }
          } header: {
            Text(section.title).font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color("SecondaryInk")).textCase(nil).help(section.id)
          }
        }
        if docs.groups(search: model.search).isEmpty && !docs.listLoading && docs.listFailure == nil
        {
          ContentUnavailableView("No matching documents", systemImage: "doc.text.magnifyingglass")
        }
        if docs.nextList != nil {
          Button("Load more documents") { Task { await model.loadDocuments(append: true) } }
        }
      }.listStyle(.plain)
      if docs.archivedCount > 0 || docs.nextList != nil {
        Divider()
        HStack(spacing: 6) {
          Image(systemName: "archivebox")
          Text(docs.archivedFooter).frame(maxWidth: .infinity, alignment: .leading)
          Button(model.includeArchivedDocuments ? "Hide" : "Show") {
            model.includeArchivedDocuments.toggle()
          }.buttonStyle(.plain).foregroundStyle(Color("TideText"))
        }.font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
          .padding(.horizontal, 12).padding(.bottom, 8)
      }
      if let error = docs.listFailure {
        Text(error).font(.caption).padding(.horizontal, 12)
        Button("Retry list") { Task { await model.loadDocuments(force: true) } }
      }
    }.padding(.top, 12)
  }

  private func proposalBanner(_ banner: DocsChromeContent.Banner) -> some View {
    HStack(alignment: .top, spacing: 10) {
      StatusDot(color: Color("Warning")).padding(.top, 4)
      Text(banner.text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
      Button("Show changes") {
        model.select(document: banner.proposal.ref)
        model.select(documentView: .changes)
      }.buttonStyle(CompactActionStyle())
      if let accepted = banner.accepted {
        Button("Read @\(accepted.revision)") {
          model.select(document: accepted.ref)
          model.select(documentView: .document)
        }.buttonStyle(CompactActionStyle())
      }
    }.padding(12).background(Color("Warning").opacity(0.08), in: .rect(cornerRadius: 8))
  }

  private func attachment(_ ref: String) -> some View {
    CopyValue(value: ref, title: "Copy attachment reference")
  }

  private var comments: some View {
    VStack(alignment: .leading, spacing: 16) {
      if docs.comments.isEmpty && phase == .ready {
        Text("No comments yet").foregroundStyle(Color("SecondaryInk"))
      }
      ForEach(docs.comments, id: \.ref) { comment in
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            ActorLabel(actor: comment.actor)
            Text(comment.kind).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
            Spacer()
            CopyValue(value: comment.ref, title: "Copy comment reference")
          }
          DocumentMarkdown(comment.body)
          Divider()
        }
      }
      if docs.nextComments != nil, let reader = model.reader, let workspace = model.workspace {
        Button("Load more comments") {
          Task { await docs.moreComments(reader, workspace: workspace) }
        }
      }
    }
  }

  private var diff: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(DocumentDiff(docs.text).lines) { line in
          Text(line.text.isEmpty ? " " : line.text).font(.system(size: 12, design: .monospaced))
            .foregroundStyle(
              line.kind == .added
                ? Color("DiffAddition")
                : line.kind == .removed
                  ? Color("Warning")
                  : line.kind == .metadata ? Color("SecondaryInk") : Color("Ink")
            )
            .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(
              line.kind == .added
                ? Color("DiffAddition").opacity(0.08)
                : line.kind == .removed ? Color("Warning").opacity(0.08) : .clear)
        }
      }.textSelection(.enabled)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider()
      HStack {
        if docs.view == .document, let lines = docs.lines {
          Text("Lines \(lines.first)–\(lines.last) of \(lines.total)")
            .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
        }
        Spacer()
        if docs.view == .document {
          Button(docs.showingSource ? "View rendered" : "View source") {
            docs.showingSource.toggle()
          }
          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color("TideText"))
        }
        if docs.nextVersions != nil, let reader = model.reader, let workspace = model.workspace {
          Button("Older revisions") {
            Task { await docs.moreVersions(reader, workspace: workspace) }
          }
        }
      }
      if docs.view == .changes, let doc = docs.document, doc.state == "proposed",
        let reader = model.reader, let workspace = model.workspace
      {
        CommandBlock(command: reader.documentTriageCommand(workspace: workspace))
      }

    }
  }

  private var listKey: String {
    "\(model.workspace ?? "")|\(model.docsAbout ?? "")|\(model.includeArchivedDocuments)|\(model.visibleData?.version ?? 0)"
  }
  private var detailKey: String {
    "\(model.workspace ?? "")|\(docs.ref ?? "")|\(docs.view.rawValue)|\(model.visibleData?.version ?? 0)"
  }
  private func show(force: Bool = false, append: Bool = false) async {
    guard let reader = model.reader, let workspace = model.workspace else { return }
    await docs.show(
      reader, workspace: workspace, version: model.visibleData?.version, force: force,
      append: append)
  }
}
