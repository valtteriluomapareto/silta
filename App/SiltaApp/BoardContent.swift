import Foundation
import SiltaAppSupport

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
  struct Answer: Identifiable {
    let command: AppCommand
    let actor: String?
    var id: String { command.text }
  }

  func questionAuthor(for ref: String) -> String? {
    attention.first { $0.kind == "question" && $0.task == ref }?.author
  }

  func answers(for ref: String, reader: AppReader, workspace: String) -> [Answer] {
    var seen = Set<String>()
    return attention.filter { $0.kind == "question" && $0.task == ref }.compactMap { item in
      guard let command = reader.commands(for: item, workspace: workspace).first,
        seen.insert(command.text).inserted
      else { return nil }
      return Answer(command: command, actor: item.author)
    }
  }
}
