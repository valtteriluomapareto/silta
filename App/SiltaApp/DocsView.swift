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
    HStack(spacing: 12) {
      documentList.frame(width: 268).seaPane()
      VStack(spacing: 0) {
        if let banner = DocsChromeContent.banner(
          document: docs.document, revisions: docs.versions, partial: docs.nextVersions != nil,
          now: model.now())
        {
          proposalBanner(banner)
        }
        GeometryReader { geometry in
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              if let document = docs.document {
                HStack(alignment: .firstTextBaseline) {
                  Text(document.title ?? document.slug).font(.system(size: 22, weight: .bold))
                    .tracking(-0.2)
                  Spacer(minLength: 12)
                  CopyValue(
                    value: document.ref, title: "Copy document reference",
                    warning: document.state == "proposed")
                }
                Text(model.screenSummary).font(.system(size: 12, weight: .medium))
                  .foregroundStyle(Color("SecondaryInk"))
                if let now = model.visibleData?.checkedAt {
                  Text(DocsContent.attribution(document, now: now))
                    .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
                }
                if let about = document.about, !about.isEmpty {
                  FlowLayout(spacing: 6, lineSpacing: 6) {
                    Text("About").font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
                      .padding(.trailing, 2).padding(.vertical, 3)
                    ForEach(about, id: \.self) { attachment($0) }
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
                  Text(
                    DocsContent.readerText(docs.document, body: docs.body, diagnostic: docs.text)
                  )
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
            }.padding(.horizontal, 44).padding(.vertical, 26)
              .frame(maxWidth: 760, minHeight: geometry.size.height, alignment: .topLeading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.frame(minWidth: 360).clipShape(.rect(cornerRadius: 18, style: .continuous)).seaCard()
    }.padding(.bottom, 12)
      .foregroundStyle(Color("Ink"))
      .task(id: listKey) { await model.loadDocuments() }
      .task(id: detailKey) { await show() }
  }

}

extension DocsView {
  private var documentList: some View {
    VStack(alignment: .leading, spacing: 12) {
      SeaSegments(
        label: "Documents", options: [(false, "All"), (true, docs.proposedLabel)],
        selection: Binding(get: { docs.proposedOnly }, set: { docs.proposedOnly = $0 })
      ).padding(.horizontal, 12)
      DocsAboutMenu(model: model).padding(.horizontal, 12)
      if docs.listLoading { ProgressView("Loading documents…").padding(.horizontal, 12) }
      List {
        ForEach(DocsContent.sections(docs.groups(search: model.search))) { section in
          Section {
            ForEach(section.groups) { group in
              if let preferred = group.preferred { documentRow(group, preferred: preferred) }
            }
          } header: {
            Text(section.title).font(.system(size: 11, weight: .semibold)).tracking(0.4)
              .textCase(.uppercase).foregroundStyle(Color("SecondaryInk"))
          }
        }
        if docs.groups(search: model.search).isEmpty && !docs.listLoading && docs.listFailure == nil
        {
          ContentUnavailableView("No matching documents", systemImage: "doc.text.magnifyingglass")
        }
        if docs.nextList != nil {
          Button("Load more documents") { Task { await model.loadDocuments(append: true) } }
        }
      }.listStyle(.plain).scrollContentBackground(.hidden)
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

  private func documentRow(_ group: DocsModel.Group, preferred: AppDocument) -> some View {
    let selected = docs.document?.slug == group.id
    let pending = group.entries.contains { $0.state == "proposed" } && !preferred.archived
    return Button {
      model.select(document: preferred.ref)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(preferred.title ?? preferred.slug)
          .font(.system(size: 13, weight: selected ? .semibold : .medium))
          .foregroundStyle(
            Color(preferred.archived ? "SecondaryInk" : selected ? "TideText" : "Ink"))
        Text(DocsContent.subtitle(group)).font(.system(size: 11)).lineLimit(2)
          .foregroundStyle(Color(pending ? "Warning" : "SecondaryInk"))
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(.rect)
    }.buttonStyle(.plain)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .listRowSeparator(.hidden)
      .listRowBackground(
        RoundedRectangle(cornerRadius: 10).fill(
          selected ? Color("AccentColor").opacity(0.08) : .clear
        ).padding(.horizontal, 6))
  }

  private func proposalBanner(_ banner: DocsChromeContent.Banner) -> some View {
    HStack(alignment: .center, spacing: 10) {
      if let actor = banner.proposal.actor {
        ActorLabel(actor: actor).labelStyle(.iconOnly).accessibilityHidden(true)
      } else {
        StatusDot(color: Color("Warning"))
      }
      Text(banner.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
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
    }.padding(.horizontal, 18).padding(.vertical, 10)
      .background(Color("Warning").opacity(0.08))
      .overlay(alignment: .bottom) {
        Rectangle().fill(Color("Warning").opacity(0.15)).frame(height: 1)
      }
  }

  private func attachment(_ ref: String) -> some View {
    Button {
      model.filterDocuments(about: ref)
    } label: {
      HStack(spacing: 6) {
        if let color = DocsAboutMenu.color(ref, map: model.visibleData?.map) {
          Circle().fill(color).frame(width: 7, height: 7)
        }
        Text(DocsContent.name(ref)).font(.system(size: 12)).lineLimit(1)
      }.padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color("Ink").opacity(0.05), in: .capsule)
    }.buttonStyle(.plain).help("Show docs about \(ref)")
      .accessibilityLabel("Show docs about " + DocsContent.name(ref))
      .contextMenu {
        Button("Copy reference") { _ = CopyValue.writeToPasteboard(ref) }
      }
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
