@testable import SiltaCore
import Testing

struct BriefBudgetTests {
  @Test func unicodeBoundaryAndAtomicRecovery() {
    let plan = BriefSection(id: "plan", text: "👩🏽‍💻éabc\n")
    let block = BriefSection(id: "blockers", text: "next: silta task show AC-1\n")
    let fitted = BriefBudget.trim([plan, block], characters: 4)
    #expect(fitted.sections == [BriefSection(id: "plan", text: "👩🏽‍💻é…\n")])
    #expect(fitted.truncated)
    #expect(BriefBudget.trim([block], characters: block.text.count - 1).sections.isEmpty)
    #expect(BriefBudget.trim([block], characters: block.text.count).sections == [block])
    #expect(!BriefBudget.trim([plan, block], characters: Int.max).truncated)
    #expect(BriefBudget.characters(tokens: Int.max) == Int.max)
    #expect(BriefBudget.trim([plan], characters: 0).sections.isEmpty)
  }
}
