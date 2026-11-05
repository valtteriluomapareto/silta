import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport

/// A database holding the Acme workspace with every exportable column set, written with
/// direct inserts so uid order differs from id order, plus a second workspace and
/// machine-local rows that must stay out of Acme's export.
enum ExportFixture {
  static let instant = Date(timeIntervalSince1970: 1_700_000_000)

  /// Machine paths stored only in rows that export never writes.
  static let machinePaths = [
    "/private/acme/platform", "/private/acme/portal-wt", "/private/acme/task-wt",
  ]

  static func store(_ home: URL) -> DatabaseStore {
    DatabaseStore(home: home, clock: FakeClock(now: instant), jitter: { 0 })
  }

  /// Creates the fixture. `offset` shifts every integer id (after inserting unrelated
  /// rows) without changing any uid, so two offsets hold the same rows under other ids.
  static func make(_ home: URL, offset: Int64 = 0) throws -> DatabaseStore {
    let store = store(home)
    try store.initialize()
    let queue = try DatabaseQueue(path: store.path)
    try queue.write { db in
      try insert(db, offset: offset)
    }
    return store
  }

  // swiftlint:disable:next function_body_length
  static func insert(_ db: Database, offset o: Int64) throws {
    func run(_ sql: String, _ arguments: [(any DatabaseValueConvertible)?]) throws {
      try db.execute(sql: sql, arguments: StatementArguments(arguments))
    }
    if o > 0 {
      try run(
        "INSERT INTO workspace(id,uid,slug,name,task_prefix) VALUES(?,?,?,?,?)",
        [o, "01HZPAD0000000000000000000", "pad", "Pad", "PD"])
    }
    let acme = 1 + o
    let other = 2 + o
    try run(
      "INSERT INTO workspace(id,uid,slug,name,task_prefix,settings) VALUES(?,?,?,?,?,?)",
      [acme, "01HZACME00000000000000WS01", "acme", "Acme", "AC", #"{"proposals":"ask"}"#])
    try run(
      "INSERT INTO workspace(id,uid,slug,name,task_prefix) VALUES(?,?,?,?,?)",
      [other, "01HZOTHR00000000000000WS02", "other", "Other", "OT"])
    try run(
      "INSERT INTO seq_counter(scope,next) VALUES(?,11),(?,2)", ["task:\(acme)", "task:\(other)"])
    try run(
      """
      INSERT INTO repo(id,uid,workspace_id,slug,remote_url,default_ref) VALUES
      (?,'01HZREPO000000000000000009',?,'platform','git@example.com:acme/platform.git','master'),
      (?,'01HZREPO000000000000000001',?,'notes','git@example.com:acme/notes.git','main')
      """, [1 + o, acme, 2 + o, acme])
    try run(
      "INSERT INTO repo_path(repo_id,path,fetched_at) VALUES(?,?,'2023-11-14T22:00:00.000Z')",
      [1 + o, machinePaths[0]])
    try run(
      """
      INSERT INTO app(id,uid,workspace_id,slug,previous_slugs,name,repo_id,ref,prod_ref,subpath,
        is_primary,stack,summary,lifecycle) VALUES
      (?,'01HZAPP0000000000000000009',?,'portal','["web"]','Acme Portal',?,'portal','portal-prod',
        'src/Portal',0,'dotnet','Customer portal','active'),
      (?,'01HZAPP0000000000000000001',?,'api','[]','Acme API',?,'api','api-prod',
        'src/Api',1,'dotnet','Public API','legacy')
      """, [1 + o, acme, 1 + o, 2 + o, acme, 1 + o])
    try run(
      """
      INSERT INTO environment(id,uid,app_id,name,url,deploy,notes) VALUES
      (?,'01HZENV0000000000000000001',?,'test','https://test.example.com','merge to test',
        'Reset nightly')
      """, [1 + o, 1 + o])
    try run(
      """
      INSERT INTO service(id,uid,workspace_id,slug,name,summary,secrets_location) VALUES
      (?,'01HZSVC0000000000000000001',?,'mailer','Mailer','Sends mail','1Password: Acme/Mailer')
      """, [1 + o, acme])
    try run(
      """
      INSERT INTO edge(id,uid,workspace_id,from_app_id,to_app_id,to_service_id,kind,summary,code_refs)
      VALUES
      (?,'01HZEDGE000000000000000009',?,?,NULL,?,'calls','Sends receipts','["portal:src/Mail.cs"]'),
      (?,'01HZEDGE000000000000000001',?,?,?,NULL,'reads','Reads orders','[]')
      """, [1 + o, acme, 1 + o, 1 + o, 2 + o, acme, 1 + o, 2 + o])
    try run(
      """
      INSERT INTO topic(id,uid,workspace_id,slug,previous_slugs,name,summary,status) VALUES
      (?,'01HZTOPC000000000000000001',?,'reports','["raports"]','Reports','Monthly reports','active')
      """, [1 + o, acme])
    try run(
      "INSERT INTO topic_alias(workspace_id,topic_id,alias) VALUES(?,?,'raportit'),(?,?,'lomakkeet')",
      [acme, 1 + o, acme, 1 + o])
    try run(
      """
      INSERT INTO source(id,uid,workspace_id,kind,root,include,exclude,repo_id) VALUES
      (?,'01HZSRC0000000000000000001',?,'repo-docs','docs','["**/*.md"]','["**/PEOPLE.md"]',?)
      """, [1 + o, acme, 2 + o])
    try run(
      "INSERT INTO worktree_override(path,app_id,set_by) VALUES(?,?,'human:acme')",
      [machinePaths[1], 1 + o])
    try insertTasks(db, offset: o, acme: acme, other: other)
  }

  // swiftlint:disable:next function_body_length
  private static func insertTasks(_ db: Database, offset o: Int64, acme: Int64, other: Int64)
    throws
  {
    func run(_ sql: String, _ arguments: [(any DatabaseValueConvertible)?]) throws {
      try db.execute(sql: sql, arguments: StatementArguments(arguments))
    }
    let columns = """
      id,uid,workspace_id,seq,title,type,status,priority,description_md,plan_md,plan_rev,
      acceptance_md,result_md,parent_id,app_id,claimed_by,claimed_at,branch,worktree,done_sha,
      done_branch,done_dirty,archive_override,external_ref,created_by,created_at,updated_at,
      closed_at,follow_up_at
      """
    try run(
      "INSERT INTO task(\(columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [
        1 + o, "01HZTASK000000000000000009", acme, 2, #"Add "sign-in""#, "feature", "blocked", 1,
        "Use the API.\n", "- [x] Inspect\n- [ ] Build\n", 2, "Signs in.", "Waiting.", nil,
        1 + o, "agent:codex:acme", "2023-11-14T22:10:00.000Z", "feature/sign-in",
        machinePaths[2], "abc1234", "feature/sign-in", 1, "kept", "gh:acme/portal#12",
        "human:acme", "2023-11-14T22:05:00.000Z", "2023-11-14T22:20:00.000Z",
        "2023-11-14T22:30:00.000Z", "2023-11-20",
      ])
    try run(
      "INSERT INTO task(\(columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [
        2 + o, "01HZTASK000000000000000001", acme, 10, "Check the callback", "chore", "done", 2,
        "~~~\n## Plan\n", "", 0, "", nil, 1 + o, 2 + o, "agent:claude:acme",
        "2023-11-14T22:40:00.000Z", "chore/callback", nil, "def5678", "master", 0, "archived",
        "ado:4711", "agent:claude:acme", "2023-11-14T22:35:00.000Z", "2023-11-14T22:45:00.000Z",
        "2023-11-14T22:45:00.000Z", "2023-11-21",
      ])
    try run(
      """
      INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
      VALUES(?,'01HZTASK0000000000000OTHR',?,1,'Other work','todo','human:other',
        '2023-11-14T22:00:00.000Z','2023-11-14T22:00:00.000Z')
      """, [3 + o, other])
    try run(
      """
      INSERT INTO task_plan_rev(id,task_id,rev,body_md,actor,created_at) VALUES
      (?,?,1,'- [ ] Inspect\n','agent:codex:acme','2023-11-14T22:11:00.000Z'),
      (?,?,2,'- [x] Inspect\n- [ ] Build\n','agent:codex:acme','2023-11-14T22:12:00.000Z')
      """, [1 + o, 1 + o, 2 + o, 1 + o])
    try run(
      """
      INSERT INTO task_event(id,task_id,actor,kind,body,created_at) VALUES
      (?,?,'human:acme','created','todo','2023-11-14T22:05:00.000Z'),
      (?,?,'human:acme','created','todo','2023-11-14T22:35:00.000Z'),
      (?,?,'agent:codex:acme','status','blocked','2023-11-14T22:20:00.000Z'),
      (?,?,'human:other','created','todo','2023-11-14T22:00:00.000Z')
      """, [1 + o, 1 + o, 2 + o, 2 + o, 3 + o, 1 + o, 4 + o, 3 + o])
    try run(
      """
      INSERT INTO comment(id,uid,task_id,doc_rev_id,seq,thread_id,kind,verdict,subject,anchor,
        anchor_sha,anchor_snippet,body_md,mentions,accepted,actor,resolved_at,resolved_by,
        deleted_at,created_at) VALUES
      (?,'01HZCMNT000000000000000009',?,NULL,1,NULL,'review','changes','plan@2','plan@2#L2',
        'abc1234','- [ ] Build','Split the build step.','["human:acme"]',0,'agent:claude:acme',
        '2023-11-14T22:25:00.000Z','agent:claude:acme',NULL,'2023-11-14T22:21:00.000Z'),
      (?,'01HZCMNT000000000000000001',?,NULL,2,?,'comment',NULL,NULL,NULL,NULL,NULL,
        'Done in plan revision 2.','[]',1,'agent:codex:acme',NULL,NULL,
        '2023-11-14T22:24:00.000Z','2023-11-14T22:22:00.000Z')
      """, [1 + o, 1 + o, 2 + o, 1 + o, 1 + o])
    try run(
      """
      INSERT INTO review_request(id,task_id,reviewer,subject,requested_by,created_at,taken_by,
        taken_at,done_at) VALUES
      (?,?,'agent:claude','plan@2','agent:codex:acme','2023-11-14T22:13:00.000Z',
        'agent:claude:acme','2023-11-14T22:14:00.000Z','2023-11-14T22:25:00.000Z')
      """, [1 + o, 1 + o])
    try run(
      """
      INSERT INTO link(id,uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,created_by,
        created_at,anchor) VALUES
      (?,'01HZLINK000000000000000009',?,'task',?,'relates','task_plan_rev',?,NULL,'human:acme',
        '2023-11-14T22:15:00.000Z','L2'),
      (?,'01HZLINK000000000000000005',?,'comment',?,'about','app',?,NULL,'human:acme',
        '2023-11-14T22:16:00.000Z',NULL),
      (?,'01HZLINK000000000000000001',?,'task',?,'cites','url',NULL,'https://example.com/acme',
        'human:acme','2023-11-14T22:17:00.000Z',NULL)
      """, [1 + o, acme, 2 + o, 2 + o, 2 + o, acme, 1 + o, 1 + o, 3 + o, acme, 1 + o])
    try run(
      """
      INSERT INTO alias_decision(workspace_id,note_ref,topic_id,decision,actor,created_at) VALUES
      (?,'note:notes/acme/weekly.md',?,'accepted','human:acme','2023-11-14T22:18:00.000Z')
      """, [acme, 1 + o])
    try run(
      """
      INSERT INTO approval(id,uid,workspace,actor,command,words,created_at) VALUES
      (?,'01HZAPRV000000000000000009','acme','agent:codex:acme','silta task triage --accept AC-10',
        'yes, accept it','2023-11-14T22:19:00.000Z'),
      (?,'01HZAPRV000000000000000001','acme','agent:codex:acme','silta task start AC-2 --steal',
        'take it over','2023-11-14T22:26:00.000Z'),
      (?,'01HZAPRV0000000000000NULL',NULL,'agent:codex:acme','silta ws edit','fine',
        '2023-11-14T22:27:00.000Z'),
      (?,'01HZAPRV0000000000000OTHR','other','agent:codex:acme','silta ws edit','ok',
        '2023-11-14T22:28:00.000Z')
      """, [1 + o, 2 + o, 3 + o, 4 + o])
  }
}
