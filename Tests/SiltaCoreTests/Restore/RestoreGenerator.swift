import Foundation
import GRDB

/// Adds seeded random rows to the fixture's Acme workspace: tasks whose parent was
/// created after them, threaded comments, links of every kind, events, plan revisions
/// and approvals, with values from an escaping corpus.
struct RestoreGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  private static let corpus = [
    "plain", "quote \" and \\", "line\nbreak", "crlf\r\nend", "tab\t", "ls\u{2028}ps", "no",
    "0123", "~~~~", "## Plan", "emoji 🧭", "e\u{301}", "", "- [ ] step",
  ]

  private mutating func next(_ bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(bound))
  }

  private mutating func text() -> String {
    (0..<(1 + next(3))).map { _ in Self.corpus[next(Self.corpus.count)] }.joined(separator: " ")
  }

  private mutating func uid(_ kind: String) -> String {
    "01HZGEN\(kind)" + String(next(Int(Int32.max)), radix: 16)
  }

  // swiftlint:disable:next function_body_length
  mutating func insert(_ db: Database) throws {
    var tasks: [Int64] = []
    var comments: [Int64] = []
    var revisions: [Int64] = []
    for index in 0..<(1 + next(5)) {
      try db.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,priority,description_md,plan_md,
            plan_rev,result_md,app_id,created_by,created_at,updated_at)
          VALUES(?,1,?,?,?,?,?,?,1,?,?,'human:acme','2023-11-15T00:00:00.000Z',
            '2023-11-15T00:00:00.000Z')
          """,
        arguments: [
          uid("T"), 20 + index, text(), ["todo", "doing", "done"][next(3)], 1 + next(3), text(),
          text(), next(2) == 0 ? nil : text(), next(2) == 0 ? nil : 1 + next(2),
        ])
      let task = db.lastInsertedRowID
      tasks.append(task)
      try db.execute(
        sql: """
          INSERT INTO task_plan_rev(task_id,rev,body_md,actor,created_at)
          VALUES(?,1,?,'agent:codex:acme','2023-11-15T00:01:00.000Z')
          """, arguments: [task, text()])
      revisions.append(db.lastInsertedRowID)
      for _ in 0..<next(3) {
        try db.execute(
          sql: """
            INSERT INTO task_event(task_id,actor,kind,body,created_at)
            VALUES(?,'human:acme','field',?,'2023-11-15T00:02:00.000Z')
            """, arguments: [task, text()])
      }
      var root: Int64?
      for seq in 1...(1 + next(3)) {
        try db.execute(
          sql: """
            INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,actor,created_at)
            VALUES(?,?,?,?,'comment',?,'agent:codex:acme','2023-11-15T00:03:00.000Z')
            """, arguments: [uid("C"), task, seq, root, text()])
        root = root ?? db.lastInsertedRowID
        comments.append(db.lastInsertedRowID)
      }
    }
    // The first generated task's parent is created after it, so its id is higher.
    try db.execute(
      sql: """
        INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
        VALUES(?,1,19,'Later parent','todo','human:acme','2023-11-15T00:04:00.000Z',
          '2023-11-15T00:04:00.000Z')
        """, arguments: [uid("P")])
    let parent = db.lastInsertedRowID
    try db.execute(sql: "UPDATE task SET parent_id=? WHERE id=?", arguments: [parent, tasks[0]])
    try db.execute(sql: "UPDATE seq_counter SET next=30 WHERE scope='task:1'")
    let ends: [(String, Int64?)] = [
      ("task", tasks[next(tasks.count)]), ("comment", comments[next(comments.count)]),
      ("task_plan_rev", revisions[next(revisions.count)]), ("app", 1), ("topic", 1),
      ("url", nil),
    ]
    for (kind, target) in ends {
      let fromTask = next(2) == 0
      try db.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,created_by,
            created_at,anchor) VALUES(?,1,?,?,'relates',?,?,?,'human:acme',
            '2023-11-15T00:05:00.000Z',?)
          """,
        arguments: [
          uid("L"), fromTask ? "task" : "comment",
          fromTask ? tasks[next(tasks.count)] : comments[next(comments.count)], kind, target,
          target == nil ? "https://example.com/\(next(1000))" : nil,
          next(2) == 0 ? nil : "L\(1 + next(9))",
        ])
    }
    for _ in 0..<next(3) {
      try db.execute(
        sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES(?,'acme','agent:codex:acme','silta ws edit',?,'2023-11-15T00:06:00.000Z')
          """, arguments: [uid("A"), text()])
    }
  }
}
