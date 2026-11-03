import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskEditUnicodeTests {
  @Test func canonicalEquivalentsRemainDistinctEditableBytes() async throws {
    await withKnownIssue("Reproduces lossless Unicode edit failure") {
      try await withScratchDirectory { home in
        let service = try TaskOrganizationTests.service(home)
        _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
        var document = TaskEditDocument(try service.show("AC-1"))
        document.title = "\u{00e9}"
        document.description = document.title
        document.acceptance = document.title
        document.plan = document.title
        document.result = document.title
        _ = try service.edit("AC-1") { _ in document.render() }
        let replacement = "e\u{0301}"
        _ = try service.edit("AC-1") { $0.replacingOccurrences(of: "\u{00e9}", with: replacement) }
        let edited = try service.show("AC-1")
        #expect(
          TaskEditDocument(edited).values.allSatisfy {
            $0.utf8.elementsEqual(replacement.utf8)
          })
        #expect(edited.planRev == 2)
      }
    }
  }
}
