@testable import SiltaCore
import Testing

struct BriefPlanTests {
  @Test func collapseKeepsOriginalOpenNumbersAndIgnoresNestedFencedBoxes() {
    let section = BriefPlan.section(
      """
      - [x] completed
        - [ ] nested
      - [ ] open
      ```
      99. [ ] example
      ```
      - [x] completed
      - [x] completed
      - [ ] next
      """, ref: "AC-1", revision: 2)
    #expect(section.text.contains("1. [x] completed\n  - [ ] nested\n2. [ ] open"))
    #expect(section.text.contains("3–4 done\n5. [ ] next"))
    #expect(section.text.contains("nested"))
    #expect(BriefPlan.through(section.text) == 5)
    let trimmed = BriefBudget.trim([section], characters: 58)
    #expect(trimmed.truncated)
    #expect(!trimmed.sections.map(\.text).joined().contains("```"))
  }

  @Test func allCompleteAndFreeformPlansRemainReadable() {
    let done = BriefPlan.section("- [x] a\n- [X] b", ref: "AC-1", revision: 0)
    #expect(done.text == "plan (revision 0):\n1–2 done\n")
    let free = BriefPlan.section("Acme freeform\n\nMore context", ref: "AC-1", revision: 0)
    #expect(free.text.contains("Acme freeform\n\nMore context"))
    #expect(
      BriefPlan.marker(ref: "AC-1", total: 60, through: 0, workspace: "acme")
        == "(plan trimmed: no steps shown (60 total); silta --ws 'acme' task show AC-1)\n")
  }
}

extension BriefPlanTests {
  @Test(arguments: ["-", "*", "+", "1.", "1)"])
  func nestedCheckboxVariants(_ marker: String) {
    let open = BriefPlan.section(
      "- [x] parent\n  \(marker) [ ] child\n- [ ] next", ref: "AC-1", revision: 0)
    #expect(open.text.contains("1. [x] parent\n  \(marker) [ ] child"))
    let fenced = BriefPlan.section(
      "- [x] parent\n  ```\n  \(marker) [ ] example\n  ```\n- [ ] next", ref: "AC-1", revision: 0)
    #expect(fenced.text.contains("1 done\n2. [ ] next"))
    #expect(!fenced.text.contains("example"))
  }
}
