import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

struct BriefDocsEmptyTopicsTests {
  @Test(arguments: ["app", "edge", "service"], [false, true])
  func emptyTopicsKeepLexicalPreviewsAndCompactCounts(kind: String, selectedTask: Bool) throws {
    try withScratchDirectory { home in
      let store = try BriefDocsTests.setup(home)
      try store.write {
        try $0.database.execute(sql: "DELETE FROM link WHERE from_kind='task' AND rel='about'")
      }
      for slug in ["zeta", "alpha", "beta"] {
        try BriefDocsTests.document(slug, target: kind, body: "Rule " + slug, store: store)
      }
      var location = try BriefDocsTests.location(home, store: store)
      if !selectedTask { location.currentTask = nil }
      for compact in [false, true] {
        if compact {
          try Self.check(store, location: location, compact: compact)
        } else {
          withKnownIssue("SI-116: Empty topic rank is interpreted as an ORDER BY column position.")
          {
            try Self.check(store, location: location, compact: compact)
          }
        }
      }
    }
  }

  private static func check(
    _ store: DatabaseStore, location: LocationResult, compact: Bool
  ) throws {
    let groups = try BriefDocsTests.context(store, location: location, compact: compact)
      .flatMap(\.documents)
    let group = try #require(groups.first)
    #expect(groups.count == 1 && group.total == 3)
    if compact {
      #expect(group.rows.isEmpty)
    } else {
      try #require(group.rows.count == 2)
      #expect(group.rows[0].contains("doc:alpha") && group.rows[1].contains("doc:beta"))
    }
  }
}
