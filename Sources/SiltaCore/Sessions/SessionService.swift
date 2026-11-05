import Foundation
import GRDB

/// Finds current-actor handoff needs without initializing, migrating or writing storage.
package struct SessionService: Sendable {
  let environment: SiltaEnvironment

  /// Uses the command's attribution and injected clock.
  package init(environment: SiltaEnvironment) { self.environment = environment }

  /// Reads fresh doing claims with meaningful own writes after the latest own handoff.
  package func check() throws -> [SessionHandoff] {
    let fresh = utcTimestamp(environment.clock.now().addingTimeInterval(-TaskService.claimDuration))
    return try environment.db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT w.slug AS workspace,w.task_prefix || '-' || t.seq AS ref
          FROM task t JOIN workspace w ON w.id=t.workspace_id
          WHERE t.claimed_by=:actor AND t.claimed_at>:fresh AND t.status='doing'
            AND t.external_ref IS NULL AND (
              EXISTS(SELECT 1 FROM task_event e WHERE e.task_id=t.id AND e.actor=:actor
                AND e.kind NOT IN ('claim','created','secret_redacted')
                AND e.id>COALESCE((SELECT MAX(h.id) FROM task_event h
                  WHERE h.task_id=t.id AND h.actor=:actor AND h.kind='claim'
                    AND h.body LIKE 'released %'),0))
              OR EXISTS(SELECT 1 FROM comment c WHERE c.task_id=t.id AND c.actor=:actor
                AND c.kind<>'handoff' AND c.seq>COALESCE((SELECT MAX(h.seq) FROM comment h
                  WHERE h.task_id=t.id AND h.actor=:actor AND h.kind='handoff'),0))
            )
          ORDER BY w.slug,t.seq
          """, arguments: ["actor": environment.actor.description, "fresh": fresh]
      ).map { SessionHandoff(workspace: $0["workspace"], ref: $0["ref"]) }
    }
  }
}
