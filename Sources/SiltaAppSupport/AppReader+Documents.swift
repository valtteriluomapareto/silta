import SiltaCore

extension AppDocument {
  init(_ value: DocDisplayMetadata) {
    self.init(
      ref: value.ref, slug: value.slug, revision: value.revision, title: value.title,
      kind: value.kind, about: value.about, state: value.state, archived: value.archived)
  }
}

extension AppReader {
  /// Lists accepted current and proposed revisions using Core attachment semantics.
  public func documents(
    workspace: String, about: String? = nil, archived: Bool = false, offset: Int = 0
  ) throws -> AppDocumentList {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      return Self.documentList(
        try DocService(workspace: workspace, store: environment.db)
          .list(about: about, archived: archived, offset: offset))
    }
  }

  /// Pages all stored revision states for a document, including historical accepted versions.
  public func documentVersions(_ ref: String, workspace: String, offset: Int = 0) throws
    -> AppDocumentList
  {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      return Self.documentList(
        try DocService(workspace: workspace, store: environment.db).revisions(ref, offset: offset))
    }
  }

  /// Reads a body or recorded-base diff without parsing CLI text for continuations.
  public func document(
    _ ref: String, workspace: String, view: AppDocumentView = .document, fromLine: Int = 1
  ) throws -> AppDocumentPage {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let value = try DocService(workspace: workspace, store: environment.db).show(
        ref,
        lines: fromLine == 1 ? nil : "\(fromLine)-\(Int.max)", diff: view == .changes,
        comments: view == .comments)
      return AppDocumentPage(
        document: value.metadata.map(AppDocument.init), body: value.body,
        text: value.rendered ?? value.output, nextLine: value.nextLine)
    }
  }

  /// Reads one discussion page with the same masking policy as the Core document reader.
  public func documentComments(_ ref: String, workspace: String, offset: Int = 0) throws
    -> AppDocumentComments
  {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let value = try DocService(workspace: workspace, store: environment.db).commentPage(
        ref, offset: offset)
      return AppDocumentComments(
        entries: value.posts.map {
          AppComment(
            ref: SecretGuard.redacted($0.ref), kind: SecretGuard.redacted($0.kind),
            actor: SecretGuard.redacted($0.actor), body: SecretGuard.redacted($0.body),
            createdAt: $0.createdAt, replyTo: $0.replyTo.map { SecretGuard.redacted($0) })
        }, total: value.total,
        nextOffset: value.offset + value.posts.count < value.total
          ? value.offset + value.posts.count : nil)
    }
  }

  private static func documentList(_ value: DocListResult) -> AppDocumentList {
    AppDocumentList(
      entries: value.entries.map { AppDocument($0.metadata) }, total: value.total,
      nextOffset: value.offset + value.entries.count < value.total
        ? value.offset + value.entries.count : nil)
  }
}
