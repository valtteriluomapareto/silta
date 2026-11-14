import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .tags(.slow), .enabled(if: slowTestsEnabled()))
struct DocInboxScenarioTests {
  @Test func restoredProposalsHaveDeterministicReadOnlyDiscovery() throws {
    var transcripts: [Data] = []
    for _ in 0..<2 {
      try withScratchDirectory { scratch in
        _ = try DocInboxCommandTests().fixture(scratch)
        let file = scratch.appending(path: "doc-inbox.yaml")
        try Data(Self.contract.utf8).write(to: file)
        transcripts.append(try ScenarioRunner.run(file, in: scratch))
      }
    }
    #expect(transcripts[0] == transcripts[1])
  }

  private static let contract = """
    steps:
      - args: [--ws, acme, inbox, --for, me, --json]
        env: {SILTA_ACTOR: 'agent:codex:acme', USER: acme}
        expect: {exit: 0, json: {data.items.0.kind: doc_proposal, data.items.0.doc_proposal.total: 3}}
      - args: [--ws, acme, doc, show, 'doc:rules@4', --diff, --json]
        env: {SILTA_ACTOR: 'agent:codex:acme', USER: acme}
        expect: {exit: 0, json: {data.ref: 'doc:rules@4'}}
      - args: [--ws, acme, doc, ls, --archived, --json]
        env: {SILTA_ACTOR: 'agent:codex:acme', USER: acme}
        expect: {exit: 0, json: {data.total: 4}}
    """
}
