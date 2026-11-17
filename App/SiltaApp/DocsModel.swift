import Foundation
import Observation
import SiltaAppSupport

@MainActor @Observable final class DocsModel {
  struct Group: Identifiable {
    let id: String
    let entries: [AppDocument]
    var preferred: AppDocument? { entries.first { $0.state == "accepted" } ?? entries.first }
  }
  var ref: String? {
    didSet {
      if oldValue != ref {
        resetContent()
        document = nil
        versions = []
        nextVersions = nil
      }
    }
  }
  var view: AppDocumentView = .document {
    didSet { if oldValue != view { resetContent() } }
  }
  private(set) var entries: [AppDocument] = []
  private(set) var nextList: Int?
  private(set) var document: AppDocument?
  private(set) var versions: [AppDocument] = []
  private(set) var nextVersions: Int?
  private(set) var body = ""
  private(set) var text = ""
  private(set) var nextLine: Int?
  private(set) var comments: [AppComment] = []
  private(set) var nextComments: Int?
  private(set) var failure: String?
  private(set) var listFailure: String?
  private(set) var loading = false
  private var listGeneration = 0
  private var generation = 0
  private var scope: Scope?
  private struct Scope: Equatable {
    let workspace: String
    let about: String?
    let archived: Bool
  }

  private func resetContent() {
    generation += 1
    loading = false
    body = ""
    text = ""
    comments = []
    nextComments = nil
    nextLine = nil
    failure = nil
  }

  func groups(search: String) -> [Group] {
    let matching = entries.filter { entry in
      search.isEmpty
        || ([entry.ref, entry.title ?? "", entry.kind ?? ""] + (entry.about ?? []))
          .contains { $0.localizedCaseInsensitiveContains(search) }
    }
    return Dictionary(grouping: matching, by: \.slug).map { Group(id: $0.key, entries: $0.value) }
      .sorted { $0.id < $1.id }
  }

  func refresh(
    _ reader: AppReader, workspace: String, about: String?, archived: Bool, append: Bool = false
  ) async {
    let requestedScope = Scope(workspace: workspace, about: about, archived: archived)
    if scope != requestedScope {
      entries = []
      nextList = nil
      listFailure = nil
      scope = requestedScope
    }
    listGeneration += 1
    let token = listGeneration
    let offset = append ? nextList ?? 0 : 0
    do {
      let result = try await Task.detached {
        try reader.documents(workspace: workspace, about: about, archived: archived, offset: offset)
      }.value
      guard token == listGeneration, !Task.isCancelled else { return }
      entries = append ? entries + result.entries : result.entries
      nextList = result.nextOffset
      listFailure = nil
    } catch {
      if token == listGeneration, !Task.isCancelled { listFailure = AppLoadFailure(error).message }
    }
  }

  func show(_ reader: AppReader, workspace: String, append: Bool = false) async {
    generation += 1
    let token = generation
    guard let requested = ref else {
      document = nil
      return
    }
    let selectedView = view
    let line = append ? nextLine ?? 1 : 1
    loading = true
    defer { if token == generation { loading = false } }
    if !append {
      body = ""
      text = ""
      comments = []
      document = nil
    }
    do {
      let result = try await Task.detached {
        Read(
          page: try reader.document(
            requested, workspace: workspace, view: selectedView, fromLine: line),
          versions: try reader.documentVersions(requested, workspace: workspace),
          comments: selectedView == .comments
            ? try reader.documentComments(requested, workspace: workspace) : nil)
      }.value
      guard token == generation, requested == ref, selectedView == view, !Task.isCancelled else {
        return
      }
      document = result.page.document
      body += result.page.body ?? ""
      text += result.page.text
      nextLine = result.page.nextLine
      if !append {
        versions = result.versions.entries
        nextVersions = result.versions.nextOffset
      }
      comments = result.comments?.entries ?? []
      nextComments = result.comments?.nextOffset
      failure = nil
    } catch {
      if token == generation, requested == ref, !Task.isCancelled {
        failure = AppLoadFailure(error).message
      }
    }
  }

  func moreVersions(_ reader: AppReader, workspace: String) async {
    guard !loading, let requested = ref, let offset = nextVersions else { return }
    let token = generation
    loading = true
    defer { if token == generation { loading = false } }
    do {
      let result = try await Task.detached {
        try reader.documentVersions(requested, workspace: workspace, offset: offset)
      }.value
      guard token == generation, requested == ref, !Task.isCancelled else { return }
      versions += result.entries
      nextVersions = result.nextOffset
    } catch {
      if token == generation, requested == ref, !Task.isCancelled {
        failure = AppLoadFailure(error).message
      }
    }
  }

  func moreComments(_ reader: AppReader, workspace: String) async {
    guard !loading, let requested = ref, let offset = nextComments else { return }
    let token = generation
    loading = true
    defer { if token == generation { loading = false } }
    do {
      let result = try await Task.detached {
        try reader.documentComments(requested, workspace: workspace, offset: offset)
      }.value
      guard token == generation, requested == ref, view == .comments, !Task.isCancelled else {
        return
      }
      comments += result.entries
      nextComments = result.nextOffset
    } catch {
      if token == generation, requested == ref, !Task.isCancelled {
        failure = AppLoadFailure(error).message
      }
    }
  }

  private struct Read: Sendable {
    let page: AppDocumentPage
    let versions: AppDocumentList
    let comments: AppDocumentComments?
  }
}
