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
  private let attention: [AppAttention]

  init(snapshot: AppSnapshot, app: String?, search: String, proposals: Bool) {
    let board = snapshot.board
    func filtered(_ tasks: [AppTask]) -> [AppTask] {
      tasks.filter { task in
        (app == nil || task.app == app)
          && AppSearch.matches(
            search,
            values: [
              task.ref, task.title, task.description, task.app ?? "", task.claimedBy ?? "",
              task.status,
            ])
      }
    }
    lanes = [
      Lane(title: "Todo", tasks: filtered(board.todo + (proposals ? board.proposals : []))),
      Lane(title: "Doing", tasks: filtered(board.doing)),
      Lane(title: "Review", tasks: filtered(board.review)),
      Lane(title: "Done this week", tasks: filtered(board.doneThisWeek)),
    ]
    attention = board.questions
    questions = Set(board.questions.compactMap(\.task))
  }
  func commands(for ref: String, reader: AppReader, workspace: String) -> [AppCommand] {
    var seen = Set<String>()
    return attention.filter { $0.kind == "question" && $0.task == ref }
      .flatMap { reader.commands(for: $0, workspace: workspace) }
      .filter { seen.insert($0.text).inserted }
  }

}
