import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct WorkspaceValidationTests {
  static let invalidCases: [(String, String)] = [
    ("", "expected a workspace mapping"),
    ("repos: []", "workspace is required"),
    (WorkspaceConfigTests.minimal + "settings: {stale_days: '14'}", "nonnegative integer"),
    (WorkspaceConfigTests.minimal + "settings: []", "expected a mapping"),
    ("workspace: [", "invalid YAML"),
    ("workspace: {slug: acme, name: 12, task_prefix: AC}", "name must be"),
    ("workspace: {slug: '-acme', name: Acme, task_prefix: AC}", "invalid slug"),
    ("workspace: {slug: acme, name: Acme, task_prefix: '-AC'}", "invalid task_prefix"),
    (WorkspaceConfigTests.minimal + "repos: wrong", "repos must be a list"),
    (WorkspaceConfigTests.minimal + "services: wrong", "services must be a list"),
    (WorkspaceConfigTests.minimal + "services: [12]", "service must be"),
    (
      WorkspaceConfigTests.minimal + "sources: [{kind: other, root: x, include: []}]", "source kind"
    ),
    (WorkspaceConfigTests.minimal + "topics: [{slug: one, aliases: [12]}]", "list of strings"),
    (
      WorkspaceConfigTests.minimal + "repos: []\napps: [{slug: api, repo: absent, ref: main}]",
      "unknown repos"
    ),
    (
      WorkspaceConfigTests.minimal + "edges: [{from: absent, to: missing, kind: http, summary: x}]",
      "unknown apps"
    ),
    (WorkspaceConfigTests.minimal + "topics: [{slug: one}, {slug: one}]", "duplicate topics"),
    (
      WorkspaceConfigTests.minimal
        + "sources: [{kind: notes, root: x, include: []}, "
        + "{kind: notes, root: x, include: []}]",
      "duplicate sources"
    ),
    (WorkspaceConfigTests.minimal + "settings: {archive_after_days: word}", "nonnegative integer"),
  ]

  @Test(arguments: invalidCases)
  func reportsEachRule(input: String, expected: String) throws {
    do {
      _ = try WorkspaceConfig.parse(input)
      Issue.record("invalid configuration accepted")
    } catch let error as WorkspaceError {
      #expect(error.code == .invalid)
      #expect(error.message.contains(expected))
      #expect(error.message.hasPrefix("line "))
    }
  }

  @Test func suggestionsIncludeTwoEditsAndExcludeThree() throws {
    let base = WorkspaceConfigTests.minimal + "repos: [{slug: platform}]\n"
    for (target, suggest) in [("platfrm", true), ("platfm", true), ("platf", false)] {
      do {
        _ = try WorkspaceConfig.parse(base + "apps: [{slug: api, repo: \(target), ref: main}]")
        Issue.record("unknown slug accepted")
      } catch let error as WorkspaceError {
        #expect(error.message.contains("did you mean platform") == suggest)
        #expect(error.message.contains("line 3"))
      }
    }
  }

  @Test func aliasesNormalizeUnicodeBeforeComparing() throws {
    #expect(throws: WorkspaceError.self) {
      try WorkspaceConfig.parse(
        WorkspaceConfigTests.minimal
          + "topics: [{slug: one, aliases: ['é']}, {slug: two, aliases: ['e\u{301}']}]")
    }
  }

  @Test func workspaceErrorsHaveGoldenRecoveryCommands() {
    let errors: [WorkspaceError] = [
      .invalid(["line 1: expected a mapping"]), .notFound, .conflict, .editor,
    ]
    let rendered = errors.map { OutputRouter.render(.failure($0), mode: .init(json: false)).stderr }
      .joined()
    Golden.forTests().check(rendered, "workspace-errors.txt")
  }
}
