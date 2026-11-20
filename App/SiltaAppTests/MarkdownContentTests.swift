#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SwiftUI
  import Synchronization
  import Testing

  struct MarkdownContentTests {
    @Test func markdownLinksShowAndProtectTheirActualDestinations() throws {
      let address = "https://example.test/docs?q=one"
      let source = """
        [Local reference](file:///acme/inert)

        [**Acme** documentation](\(address))

        [Relative reference](/acme/notes)

        `[Sample](https://example.test/sample)`
        """
      let blocks = MarkdownContent(source).blocks
      let local = try #require(blocks.first { String($0.text.characters) == "Local reference" })
      #expect(local.text.runs.compactMap(\.link).isEmpty)
      let relative = try #require(
        blocks.first { String($0.text.characters) == "Relative reference" })
      #expect(relative.text.runs.compactMap(\.link).isEmpty)
      let allowed = try #require(
        blocks.first { String($0.text.characters).hasPrefix("Acme documentation") })
      #expect(Set(allowed.text.runs.compactMap { $0.link?.absoluteString }) == [address])
      #expect(String(allowed.text.characters) == "Acme documentation (\(address))")
      let sample = try #require(blocks.first { String($0.text.characters).hasPrefix("[Sample]") })
      #expect(sample.text.runs.compactMap(\.link).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func sharedLinkActionChecksTheActualDestination() async throws {
      let opened = Mutex<[URL]>([])
      let action = DocumentMarkdown.linkAction { url in
        opened.withLock { $0.append(url) }
        return .handled
      }
      let accepted = ["https://example.test/docs", "http://example.test/read"]
      let rejected = ["file:///acme/inert", "acme:reference", "https:reference", "/acme/notes"]
      for address in accepted + rejected {
        let url = try #require(URL(string: address))
        let handled = await withCheckedContinuation { continuation in
          action(url) { continuation.resume(returning: $0) }
        }
        #expect(handled == accepted.contains(address))
      }
      #expect(opened.withLock { $0.map(\.absoluteString) } == accepted)
    }

    @Test func markdownTablesKeepColumnsEscapesAndCheckedLinks() throws {
      let source = """
        Before

        | App | Env | URL |
        |---|---|---|
        | `acme-web` | test | [site](https://test.acme.example) |
        | acme-pdf |  | a \\| b |
        | acme-crm | prod | [local](file:///acme) |
        | acme-auth | prod | https://auth.acme.example |

        After
        """
      let blocks = MarkdownContent(source).blocks
      let shape = blocks.map { $0.table == nil ? String($0.text.characters) : "table" }
      #expect(shape == ["Before", "table", "After"])
      let table = try #require(blocks[1].table)
      let rows = table.rows.map { $0.map { String($0.characters) } }
      #expect(rows[0][0] == "acme-web")
      #expect(rows[1] == ["acme-pdf", "", "a | b"])
      #expect(rows[0][2] == "site (https://test.acme.example)")
      #expect(table.rows[0][2].runs.compactMap(\.link).count == 1)
      #expect(rows[2][2] == "local" && table.rows[2][2].runs.compactMap(\.link).isEmpty)
      #expect(rows[3][2] == "https://auth.acme.example")
      #expect(table.rows[3][2].runs.compactMap(\.link).count == 1)
      let listed = MarkdownContent("- item\n\n  | x | y |\n  |---|---|\n  | 1 | 2 |\n").blocks
      #expect(listed.compactMap(\.table).count == 1)
      let two = MarkdownContent("| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |\n").blocks
      let gap = MarkdownContent("| a | b |\n|---|---|\n|  |  |\n| c | d |\n").blocks
      let gapRows = gap.compactMap(\.table).first?.rows.map { $0.map { String($0.characters) } }
      #expect(gapRows == [["", ""], ["c", "d"]])
      let headers = two.compactMap(\.table).map { $0.header.map { String($0.characters) } }
      #expect(headers == [["a"], ["b"]])
    }

    @Test func markdownTablesAndDiffRemainReadable() throws {
      let table = "| Name | Value |\n| --- | ---: |\n| amount | 42 |"
      let content = MarkdownContent("# Contract\n\n" + table, title: "Contract")
      #expect(!content.blocks.contains { $0.header == 1 })
      #expect(!content.blocks.contains { $0.code })
      let parsed = try #require(content.blocks.compactMap(\.table).first)
      #expect(parsed.header.map { String($0.characters) } == ["Name", "Value"])
      #expect(parsed.rows.map { $0.map { String($0.characters) } } == [["amount", "42"]])
      #expect(parsed.trailing == [false, true])
      let fenced = MarkdownContent("```text\n" + table + "\n```")
      #expect(fenced.blocks.filter(\.code).count == 1)
      #expect(fenced.blocks.allSatisfy { $0.table == nil })
      let diff = DocumentDiff("--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n same")
      #expect(
        diff.lines.map(\.kind) == [.metadata, .metadata, .metadata, .removed, .added, .context])
    }
  }
#endif
