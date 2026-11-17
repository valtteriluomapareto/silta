/// One masked immutable revision descriptor; nil metadata was not recorded.
public struct AppDocument: Equatable, Sendable {
  /// Canonical pinned reference.
  public let ref: String
  /// Document slug.
  public let slug: String
  /// Immutable revision number.
  public let revision: Int
  /// Bounded display title, if recorded.
  public let title: String?
  /// Document kind, if recorded.
  public let kind: String?
  /// Recorded attachments; nil means unknown historical metadata.
  public let about: [String]?
  /// Stored revision state.
  public let state: String
  /// Current archive status of the document.
  public let archived: Bool
}

/// One bounded list or history page.
public struct AppDocumentList: Equatable, Sendable {
  /// Selected revisions.
  public let entries: [AppDocument]
  /// Matching revisions before pagination.
  public let total: Int
  /// Continuation offset, if another page exists.
  public let nextOffset: Int?
}

/// Document presentation selected by the reader.
public enum AppDocumentView: String, CaseIterable, Sendable { case document, changes, comments }

/// A masked body/diff window with authoritative continuation metadata.
public struct AppDocumentPage: Equatable, Sendable {
  /// Selected revision metadata, or nil for a document without an accepted revision.
  public let document: AppDocument?
  /// Visible body Markdown, preserving its source ending.
  public let body: String?
  /// Visible masked rendering without CLI continuation text.
  public let text: String
  /// Next rendered line, independent of the CLI text format.
  public let nextLine: Int?
}

/// One bounded page of masked revision comments.
public struct AppDocumentComments: Equatable, Sendable {
  /// Current discussion values.
  public let entries: [AppComment]
  /// Total discussion posts.
  public let total: Int
  /// Next page offset, if present.
  public let nextOffset: Int?
}
