import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct RetiredMapSlugCommandTests {
  private let original = """
    workspace: {slug: acme, name: Acme, task_prefix: AC}
    repos: [{slug: platform}]
    apps: [{slug: api, repo: platform, ref: main}]
    topics: [{slug: api, aliases: [Messages]}, {slug: other, aliases: [Alerts]}]

    """

  private let withoutAPI = """
    workspace: {slug: acme, name: Acme, task_prefix: AC}
    repos: [{slug: platform}]
    apps: []
    topics: [{slug: other, aliases: [Alerts]}]

    """

  @Test func removalReservesEveryNameAndReleaseIsScoped() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      let first = original.replacingOccurrences(
        of: "slug: api, repo:", with: "slug: delivery, previous: [api], repo:")
      let second = original.replacingOccurrences(
        of: "slug: api, repo:", with: "slug: shipping, previous: [delivery], repo:")
      let uid = try appUID(store)
      try saved(first, scratch)
      try saved(second, scratch)
      let linked = try run(["task", "ls", "--app", "api", "--json"], scratch)
      #expect(linked.termination == .exit(0) && linked.stdout.contains("renamed"))
      #expect(linked.stdout.contains("renamed to shipping"))
      #expect(try appUID(store) == uid)
      let removal = try changes(withoutAPI, scratch)
      #expect(
        removal["retired"] as? [String] == ["app:api", "app:delivery", "app:shipping", "topic:api"])
      try saved(withoutAPI, scratch)
      let exported = try show(scratch)
      let staleStamp = try stamp(exported)
      #expect(exported.contains("# Retired app slugs: api, delivery, shipping"))
      #expect(exported.contains("# Retired topic slugs: api"))
      let add = withoutAPI.replacingOccurrences(
        of: "apps: []", with: "apps: [{slug: shipping, repo: platform, ref: main}]")
      let refused = try edit(add, scratch)
      #expect(
        (try TaskStateCommandTests.error(refused)["message"] as? String)?
          .contains("App slug shipping is retired") == true)
      let released = add + "released: {apps: [api, delivery, shipping]}\n"
      let unstamped = try edit(released, scratch)
      #expect(unstamped.termination == .exit(1))
      let reuse = try changes(staleStamp + released, scratch)
      #expect(reuse["released"] as? [String] == ["app:api", "app:delivery", "app:shipping"])
      #expect(reuse["added"] as? [String] == ["app:shipping"])
      #expect(try show(scratch) == exported)
      try saved(staleStamp + released, scratch)
      #expect(try appUID(store) != uid)
      let current = try show(scratch)
      #expect(!current.contains("Retired app slugs") && current.contains("Retired topic slugs"))
      #expect(try edit(staleStamp + released, scratch).termination == .exit(6))
      try saved(current + "released: {topics: [api]}\n", scratch)
      #expect(!(try show(scratch)).contains("Retired topic slugs"))
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT settings FROM workspace")
        } == "{}")
    }
  }

  @Test func refusesReleaseOfLiveHistoricalUnknownAndNewlyRetiredNames() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      let renamed = original.replacingOccurrences(
        of: "slug: api, repo:", with: "slug: delivery, previous: [api], repo:")
      try saved(renamed, scratch)
      let shown = try show(scratch)
      let removed = renamed.replacingOccurrences(
        of: "apps: [{slug: delivery, previous: [api], repo: platform, ref: main}]", with: "apps: []"
      )
      let initialStamp = try stamp(shown)
      for (yaml, name) in [
        (renamed, "delivery"), (renamed, "api"), (renamed, "unknown"), (removed, "delivery"),
      ] {
        let input = initialStamp + yaml + "released: {apps: [\(name)]}\n"
        for preview in [true, false] {
          let result = try edit(input, scratch, preview: preview)
          let error = try TaskStateCommandTests.error(result)
          #expect(result.termination == .exit(1))
          #expect(
            (error["message"] as? String)?.contains("App slug \(name) is not already retired.")
              == true)
        }
      }
      #expect(try show(scratch) == shown)
    }
  }

  @Test func exportRestoreRetainsBothNamespaces() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      let removed = """
        workspace: {slug: acme, name: Acme, task_prefix: AC}
        apps: []
        topics: []

        """
      try saved(removed, scratch)
      let root = scratch.appending(path: "out")
      let export = try run(["export", "--to", root.path], scratch)
      try #require(export.termination == .exit(0), "\(export.stdout)\(export.stderr)")
      try withScratchDirectory { restored in
        let tree = root.appending(path: "acme").path
        let result = try run(["restore", tree, "--approved", "Restore Acme."], restored)
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        let shown = try show(restored)
        #expect(shown.contains("# Retired app slugs: api"))
        #expect(shown.contains("# Retired topic slugs: api, other"))
        let resultAfterRestore = try edit(original, restored, preview: true)
        #expect(resultAfterRestore.termination == .exit(1))
        #expect(resultAfterRestore.stdout.contains("App slug api is retired"))
      }
    }
  }

}

extension RetiredMapSlugCommandTests {
  @Test func staleReleaseCannotClearAReplacementIdentitysReservation() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      try saved(withoutAPI, scratch)
      let initial = try show(scratch)
      let release = "released: {apps: [api]}\n"
      let stale = initial + release
      let task = try run(["task", "add", "Unrelated Acme work", "--app", "none"], scratch)
      try #require(task.termination == .exit(0), "\(task.stdout)\(task.stderr)")
      #expect(try show(scratch) == initial)
      let reuse = withoutAPI.replacingOccurrences(
        of: "apps: []", with: "apps: [{slug: api, repo: platform, ref: main}]")
      try saved(stamp(initial) + reuse + release, scratch)
      try saved(withoutAPI, scratch)
      let replacement = try show(scratch)
      #expect(
        replacement.split(separator: "\n").dropFirst() == initial.split(separator: "\n").dropFirst()
      )
      #expect(replacement != initial)
      let count = try approvals(store)
      for preview in [true, false] {
        let result = try edit(stale, scratch, preview: preview)
        #expect(result.termination == .exit(6), "\(result.stdout)\(result.stderr)")
        #expect(
          try TaskStateCommandTests.error(result)["next"] as? [String] == [
            "silta --ws 'acme' ws show"
          ])
      }
      #expect(try show(scratch) == replacement)
      #expect(try approvals(store) == count)
    }
  }

  @Test func releaseWarnsAboutOldReferencesInBothOutputModes() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      try saved(withoutAPI, scratch)
      let draft = try show(scratch) + "released: {apps: [api]}\n"
      let warning = "Released references may resolve to a new identity when reused."
      let text = try edit(draft, scratch, preview: true, json: false)
      #expect(text.termination == .exit(0) && text.stderr.contains(warning))
      for preview in [true, false] {
        let result = try edit(draft, scratch, preview: preview)
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(try TaskStateCommandTests.warnings(result).contains("released_map_slug"))
        #expect(result.stdout.contains(warning))
      }
    }
  }

  @Test func aliasPreviewTracksAnOwnerMoveAndIgnoresCaseOnlyChanges() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      let shown = try show(scratch)
      let caseOnly = original.replacingOccurrences(of: "[Messages]", with: "[MESSAGES]")
      let moved = original.replacingOccurrences(of: ", aliases: [Messages]", with: "")
        .replacingOccurrences(of: "[Alerts]", with: "[Alerts, Messages]")
      let preview = try edit(moved, scratch, preview: true)
      let changes = try #require(
        (try TaskStateCommandTests.data(preview))["changes"] as? [String: Any])
      let aliases = try #require(changes["aliases_changed"] as? [[String: Any]])
      #expect(aliases.count == 2)
      #expect(aliases.first?["topic"] as? String == "topic:api")
      #expect(aliases.first?["removed"] as? [String] == ["messages"])
      #expect(aliases.last?["topic"] as? String == "topic:other")
      #expect(aliases.last?["added"] as? [String] == ["messages"])
      let unchanged = try edit(caseOnly, scratch, preview: true)
      #expect(!unchanged.stdout.contains("aliases_changed"))
      #expect(try show(scratch) == shown)
    }
  }

  @Test func previewShowsNormalizationOfALegacyStoredAlias() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      try AcmeDocAttachments.apply(original, to: store)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE topic_alias SET alias='MESSAGES' WHERE alias='messages'")
      }
      let preview = try changes(original, scratch)
      let aliases = try #require(preview["aliases_changed"] as? [[String: Any]])
      #expect(aliases.count == 1)
      #expect(aliases.first?["topic"] as? String == "topic:api")
      #expect(aliases.first?["removed"] as? [String] == ["MESSAGES"])
      #expect(aliases.first?["added"] as? [String] == ["messages"])
      try saved(original, scratch)
      #expect(try changes(original, scratch)["aliases_changed"] == nil)
    }
  }

  @Test func collisionsNameTheContestedSlugAndOwner() throws {
    try withScratchDirectory { scratch in
      let store = BriefCommandTests().store(scratch)
      let start = original.replacingOccurrences(
        of: "apps: [", with: "apps: [{slug: site, repo: platform, ref: website}, ")
      try AcmeDocAttachments.apply(start, to: store)
      let duplicate = original.replacingOccurrences(
        of: "apps: [{slug: api, repo: platform, ref: main}]",
        with: """
          apps: [{slug: first, previous: [api], repo: platform, ref: main},
                 {slug: second, previous: [api], repo: platform, ref: next}]
          """)
      let collision = original.replacingOccurrences(
        of: "slug: api, repo:", with: "slug: site, previous: [api], repo:")
      let reserved = original.replacingOccurrences(
        of: "slug: api, repo:", with: "slug: doc, previous: [api], repo:")
      for (yaml, expected) in [
        (duplicate, "App slug api belongs to app:api"),
        (collision, "App slug site belongs to app:site"),
        (reserved, "Cannot rename an app to reserved slug doc"),
      ] {
        let result = try edit(yaml, scratch, preview: true)
        let error = try TaskStateCommandTests.error(result)
        #expect((error["message"] as? String)?.contains(expected) == true)
      }
    }
  }

  @Test func docEditDeduplicatesOnlyIdenticalRenameWarnings() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let renamed = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "slug: api, repo:", with: "slug: delivery, previous: [api], repo:"
      ).replacingOccurrences(of: "slug: messaging", with: "slug: alerts, previous: [messaging]")
      try AcmeDocAttachments.apply(renamed, to: store)
      let body = scratch.appending(path: "rules.md")
      try "Acme rule.\n".write(to: body, atomically: true, encoding: .utf8)
      let result = try run(
        [
          "doc", "edit", "rules", "--title", "Acme rules", "--kind", "reference",
          "--about", "app:api", "--about", "edge:api/service:push/sdk",
          "--about", "topic:messaging", "-F", body.path,
          "--approved", "Save the Acme rules.", "--json",
        ], scratch)
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      let data = try GuideContractTests.object(result.stdout)
      let warnings = try #require(data["warnings"] as? [[String: String]])
        .filter { $0["code"] == "renamed" }
      #expect(warnings.count == 2)
      #expect(warnings.contains { $0["message"]?.contains("App api was renamed") == true })
      #expect(
        warnings.contains { $0["message"]?.contains("Topic messaging was renamed") == true })
    }
  }

  private func appUID(_ store: DatabaseStore) throws -> String? {
    try store.read { try String.fetchOne($0, sql: "SELECT uid FROM app") }
  }

  private func changes(_ yaml: String, _ scratch: URL) throws -> [String: Any] {
    let preview = try edit(yaml, scratch, preview: true)
    return try #require((try TaskStateCommandTests.data(preview))["changes"] as? [String: Any])
  }

  private func approvals(_ store: DatabaseStore) throws -> Int? {
    try store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM approval") }
  }

  private func edit(_ yaml: String, _ scratch: URL, preview: Bool = false, json: Bool = true)
    throws -> CLIResult
  {
    let file = scratch.appending(path: "workspace.yml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    let mode = preview ? ["--dry-run"] : ["--approved", "Apply the Acme workspace edit."]
    return try run(["ws", "edit", "-F", file.path] + (json ? ["--json"] : []) + mode, scratch)
  }

  private func saved(_ yaml: String, _ scratch: URL) throws {
    let result = try edit(yaml, scratch)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
  }

  private func show(_ scratch: URL) throws -> String {
    let result = try run(["ws", "show"], scratch)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    return result.stdout
  }

  private func stamp(_ document: String) throws -> String {
    try #require(document.components(separatedBy: "\n").first) + "\n"
  }

  private func run(_ args: [String], _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme"] + args, in: scratch,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }
}
