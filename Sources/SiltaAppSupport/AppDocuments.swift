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
  /// Recorded, masked revision attribution; nil means not recorded.
  public var actor: String?
  /// Recorded, masked revision attribution; nil means not recorded.
  public var createdAt: String?
  /// Recorded, masked revision attribution; nil means not recorded.
  public var sourceTask: String?
  /// Recorded, masked revision attribution; nil means not recorded.
  public var message: String?
  /// Recorded, masked revision attribution; nil means not recorded.
  public var triagedBy: String?
  /// Recorded, masked revision attribution; nil means not recorded.
  public var triagedAt: String?
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
public enum AppDocumentView: String, CaseIterable, Hashable, Sendable {
  case document, changes, comments
}

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
  /// Visible masked body line numbers; absent for changes and comments.
  public var lines: AppDocumentLines?
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

/// Body line positions supplied by the document reader.
public struct AppDocumentLines: Equatable, Sendable {
  /// First visible body line, or zero for an empty window.
  public let first: Int
  /// Last visible body line, or zero for an empty window.
  public let last: Int
  /// Total masked body lines.
  public let total: Int

  /// Combines consecutive body windows without deriving numbers from rendered text.
  public func appending(_ next: Self) -> Self {
    Self(first: first == 0 ? next.first : first, last: next.last, total: next.total)
  }
}
