import Foundation
import SiltaAppSupport

/// What the Board shows. Only `blocked` and `done` persist; an app choice and shown
/// proposals last for the session, as they did before filters.
nonisolated struct BoardFilter: Equatable {
  var app: String?
  var proposals = false
  var blocked = true
  var done = true

  /// Filters that take tasks away: an app, hidden blocked tasks, hidden done tasks.
  /// Showing proposals adds tasks, so it does not count.
  var narrowingCount: Int { (app == nil ? 0 : 1) + (blocked ? 0 : 1) + (done ? 0 : 1) }
  var isDefault: Bool { self == BoardFilter() }

  /// The toolbar label: "Filter", the chosen app, or "Filtered", with the narrowing count
  /// when more than the app narrows the board.
  func title(apps: [AppMapApp]) -> String {
    let name = app.map(apps.name(of:))
    switch (name, narrowingCount) {
    case (nil, 0): return "Filter"
    case (let name?, 1): return name
    case (let name, let count): return (name ?? "Filtered") + " · \(count)"
    }
  }
}

extension [AppMapApp] {
  /// The display name of the app with this slug, or the slug when the map lacks the app.
  nonisolated func name(of slug: String) -> String { first { $0.slug == slug }?.name ?? slug }
}

nonisolated struct BoardContent {
  struct Lane: Identifiable {
    let title: String
    let tasks: [AppTask]
    var id: String { title }
  }
  /// Tasks each Show toggle adds or removes, given the current app and search.
  struct Counts: Equatable {
    let blocked: Int
    let proposed: Int
    let done: Int
  }
  struct AppLabel: Equatable {
    let name: String
    /// The sidebar's colour asset; nil for an app missing from the map.
    let color: String?
  }
  let lanes: [Lane]
  let questions: Set<String>
  let counts: Counts
  /// Blocked tasks the filter took off Todo. Blocked tasks that ask the human stay.
  let hiddenBlocked: Int
  private let attention: [AppAttention]
  private let apps: [AppMapApp]
  private let colours: [String: String]

  init(
    snapshot: AppSnapshot, apps: [AppMapApp], filter: BoardFilter, search: String,
    colours: [String: String] = [:]
  ) {
    let board = snapshot.board
    let questions = Set(board.questions.compactMap(\.task))
    func filtered(_ tasks: [AppTask]) -> [AppTask] {
      tasks.filter { task in
        (filter.app == nil || task.app == filter.app)
          && AppSearch.matches(
            search,
            values: [
              task.ref, task.title, task.description, task.app ?? "",
              Self.appLabel(task.app, apps: apps, colours: colours)?.name ?? "",
              task.claimedBy ?? "", task.status,
            ])
      }
    }
    func hideable(_ task: AppTask) -> Bool {
      task.status == "blocked" && !questions.contains(task.ref)
    }
    let todo = filtered(board.todo)
    let hidden = todo.filter(hideable)
    let proposals = filtered(board.proposals)
    let done = filtered(board.doneThisWeek)
    let shownTodo = filter.blocked ? todo : todo.filter { !hideable($0) }
    lanes =
      [
        Lane(title: "Todo", tasks: shownTodo + (filter.proposals ? proposals : [])),
        Lane(title: "Doing", tasks: filtered(board.doing)),
        Lane(title: "Review", tasks: filtered(board.review)),
      ] + (filter.done ? [Lane(title: "Done this week", tasks: done)] : [])
    counts = Counts(blocked: hidden.count, proposed: proposals.count, done: done.count)
    hiddenBlocked = filter.blocked ? 0 : hidden.count
    attention = board.questions
    self.questions = questions
    self.apps = apps
    self.colours = colours
  }

  /// The Todo footnote for hidden blocked tasks; nil when none are hidden.
  var hiddenBlockedText: String? {
    switch hiddenBlocked {
    case 0: nil
    case 1: "1 blocked task hidden"
    default: "\(hiddenBlocked) blocked tasks hidden"
    }
  }

  static func appLabel(_ slug: String?, apps: [AppMapApp], colours: [String: String])
    -> AppLabel?
  {
    guard let slug else { return nil }
    return AppLabel(
      name: apps.name(of: slug),
      color: SidebarContent.appColor(slug: slug, apps: apps, chosen: colours))
  }

  func appLabel(for task: AppTask) -> AppLabel? {
    Self.appLabel(task.app, apps: apps, colours: colours)
  }

  func accessibilityLabel(for task: AppTask, asked: Bool) -> String {
    task.ref + ": " + task.title + (appLabel(for: task).map { ", " + $0.name } ?? "") + ", "
      + task.status + (asked ? ", asked you" : "")
      + (task.steps.isEmpty
        ? "" : ", " + TaskPresentation.progress(task.steps, revision: task.planRevision))
  }

  struct Answer: Identifiable {
    let command: AppCommand
    let actor: String?
    /// The question's comment reference, which an answer replies to.
    var question: String?
    var createdAt: String?
    var id: String { command.text }
  }

  /// The newest open question to the human on a task: the one the inspector answers.
  func newestQuestion(for ref: String, reader: AppReader, workspace: String) -> Answer? {
    answers(for: ref, reader: reader, workspace: workspace).filter { $0.question != nil }
      .max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
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
      return Answer(
        command: command, actor: item.author, question: item.ref, createdAt: item.createdAt)
    }
  }
}
