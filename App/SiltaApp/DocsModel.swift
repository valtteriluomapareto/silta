import Foundation
import Observation
import SiltaAppSupport

@MainActor @Observable final class DocsModel {
  typealias ListLoader =
    @MainActor (AppReader, String, String?, Bool, Int) async throws ->
    AppDocumentList
  typealias VersionsLoader =
    @MainActor (AppReader, String, String, Int) async throws ->
    AppDocumentList
  private let readList: ListLoader
  private let readVersions: VersionsLoader

  init(
    readList: @escaping ListLoader = { reader, workspace, about, archived, offset in
      try await Task.detached {
        try reader.documents(workspace: workspace, about: about, archived: archived, offset: offset)
      }.value
    },
    readVersions: @escaping VersionsLoader = { reader, ref, workspace, offset in
      try await Task.detached {
        try reader.documentVersions(ref, workspace: workspace, offset: offset)
      }.value
    }
  ) {
    self.readList = readList
    self.readVersions = readVersions
  }

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
  var proposedOnly = false
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
  private(set) var listLoading = false
  private var detailWorkspace: String?
  private var loadedKey: DetailKey?
  private var listVersion: Int?
  private var listLoaded = false
  private struct DetailKey: Equatable {
    let workspace: String
    let ref: String
    let view: AppDocumentView
    let version: Int?
  }
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
    loadedKey = nil
    loading = false
    body = ""
    text = ""
    comments = []
    nextComments = nil
    nextLine = nil
    failure = nil
  }

  func clear() {
    listGeneration += 1
    resetContent()
    ref = nil
    document = nil
    versions = []
    nextVersions = nil
    entries = []
    nextList = nil
    listFailure = nil
    listLoading = false
    listLoaded = false
    scope = nil
    detailWorkspace = nil
  }

  func groups(search: String) -> [Group] {
    let matching = entries.filter { entry in
      (!proposedOnly || entry.state == "proposed")
        && AppSearch.matches(
          search,
          values: [entry.ref, entry.title ?? "", entry.kind ?? ""]
            + (entry.about ?? []))
    }
    return Dictionary(grouping: matching, by: \.slug).map { Group(id: $0.key, entries: $0.value) }
      .sorted { $0.id < $1.id }
  }

  @discardableResult
  func refresh(
    _ reader: AppReader, workspace: String, about: String?, archived: Bool,
    version: Int? = nil, force: Bool = false, append: Bool = false
  ) async -> Int? {
    let requestedScope = Scope(workspace: workspace, about: about, archived: archived)
    if !force, !append, listLoaded, listFailure == nil,
      scope == requestedScope, listVersion == version
    {
      return listGeneration
    }
    if scope != requestedScope {
      listLoaded = false
      entries = []
      nextList = nil
      listFailure = nil
      scope = requestedScope
    }
    listGeneration += 1
    let token = listGeneration
    let offset = append ? nextList ?? 0 : 0
    listLoading = true
    defer { if token == listGeneration { listLoading = false } }
    do {
      let result = try await readList(reader, workspace, about, archived, offset)
      guard token == listGeneration, !Task.isCancelled else { return nil }
      entries = append ? entries + result.entries : result.entries
      nextList = result.nextOffset
      listFailure = nil
      listLoaded = true
      listVersion = version
      return token
    } catch {
      if token == listGeneration, !Task.isCancelled {
        listFailure = AppLoadFailure(error).message
        return token
      }
    }
    return nil
  }

  func isCurrentList(_ request: Int) -> Bool { request == listGeneration }

  func show(
    _ reader: AppReader, workspace: String, version: Int? = nil,
    force: Bool = false, append: Bool = false
  ) async {
    guard let requested = ref else {
      document = nil
      return
    }
    let key = DetailKey(workspace: workspace, ref: requested, view: view, version: version)
    if !force, !append, failure == nil, loadedKey == key { return }
    if detailWorkspace != workspace {
      resetContent()
      document = nil
      detailWorkspace = workspace
    }
    generation += 1
    let token = generation
    let selectedView = view
    let line = append ? nextLine ?? 1 : 1
    let preserveBody =
      !append && selectedView == .document
      && document?.ref == requested && !body.isEmpty
    loading = true
    defer { if token == generation { loading = false } }
    do {
      let (page, comments) = try await Task.detached {
        let page = try reader.document(
          requested, workspace: workspace, view: selectedView, fromLine: line)
        let comments =
          selectedView == .comments
          ? try reader.documentComments(requested, workspace: workspace) : nil
        return (page, comments)
      }.value
      let history = try await readVersions(reader, requested, workspace, 0)
      let result = Read(page: page, versions: history, comments: comments)
      guard token == generation, requested == ref, selectedView == view, !Task.isCancelled else {
        return
      }
      apply(result, append: append, preserveBody: preserveBody)
      loadedKey = key
    } catch {
      if token == generation, requested == ref, !Task.isCancelled {
        failure = AppLoadFailure(error).message
      }
    }
  }

  private func apply(_ result: Read, append: Bool, preserveBody: Bool) {
    document = result.page.document
    if !preserveBody {
      body = (append ? body : "") + (result.page.body ?? "")
      text = (append ? text : "") + result.page.text
      nextLine = result.page.nextLine
    }
    if !append {
      versions = result.versions.entries
      nextVersions = result.versions.nextOffset
    }
    comments = result.comments?.entries ?? []
    nextComments = result.comments?.nextOffset
    failure = nil
  }

}

extension DocsModel {
  func moreVersions(_ reader: AppReader, workspace: String) async {
    guard !loading, let requested = ref, let offset = nextVersions else { return }
    let token = generation
    loading = true
    defer { if token == generation { loading = false } }
    do {
      let result = try await readVersions(reader, requested, workspace, offset)
      guard token == generation, requested == ref, !Task.isCancelled else { return }
      versions += result.entries
      nextVersions = result.nextOffset
      failure = nil
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
      failure = nil
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
