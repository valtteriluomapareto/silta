import SiltaAppSupport
import Foundation

nonisolated struct BoardContent {
  struct Lane: Identifiable {
    let title: String
    let tasks: [AppTask]
    var id: String { title }
  }
  let lanes: [Lane]
  let questions: Set<String>

  init(snapshot: AppSnapshot, app: String?, search: String, proposals: Bool) {
    let board = snapshot.board
    func filtered(_ tasks: [AppTask]) -> [AppTask] {
      tasks.filter { task in
        (app == nil || task.app == app)
          && (search.isEmpty
            || [
              task.ref, task.title, task.description, task.app ?? "", task.claimedBy ?? "",
              task.status,
            ]
            .contains { $0.localizedCaseInsensitiveContains(search) })
      }
    }
    lanes = [
      Lane(title: "Todo", tasks: filtered(board.todo + (proposals ? board.proposals : []))),
      Lane(title: "Doing", tasks: filtered(board.doing)),
      Lane(title: "Review", tasks: filtered(board.review)),
      Lane(title: "Done this week", tasks: filtered(board.doneThisWeek)),
    ]
    questions = Set(snapshot.work.items.filter { $0.kind == "question" }.compactMap(\.task))
  }
}
