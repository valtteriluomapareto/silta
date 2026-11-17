import GRDB

/// Frozen identity admission shared by migration and read-only diagnosis.
enum StoredUIDV9 {
  static func unsupported(in db: Database) throws -> Bool {
    for table in [
      "workspace", "repo", "app", "environment", "service", "edge", "topic", "task",
      "comment", "doc", "doc_rev", "link", "source", "approval", "doc_verification",
    ] where try db.tableExists(table) {
      if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(invalid("uid")))")
        == true
      {
        return true
      }
    }
    for (table, column, required) in [
      ("doc_rev", "about_targets", true), ("doc_verification", "app_shas", false),
    ] {
      guard try db.tableExists(table),
        try db.columns(in: table).contains(where: { $0.name == column })
      else { continue }
      let bad = """
        CASE WHEN \(column) IS NULL THEN 0
          WHEN typeof(\(column))<>'text' OR NOT json_valid(\(column)) THEN 1
          WHEN json_type(\(column))<>'array' THEN 1
          ELSE EXISTS(SELECT 1 FROM json_each(\(column)) e WHERE
            CASE WHEN e.type<>'object' THEN 1
              WHEN json_type(e.value,'$.uid') IS NULL OR json_type(e.value,'$.uid')='null'
                THEN \(required ? 1 : 0)
              WHEN json_type(e.value,'$.uid')<>'text' THEN 1
              ELSE \(invalid("json_extract(e.value,'$.uid')")) END) END
        """
      if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(bad))") == true {
        return true
      }
    }
    return false
  }

  private static func invalid(_ value: String) -> String {
    "typeof(\(value))<>'text' OR length(CAST(\(value) AS BLOB))=0 OR instr(\(value),char(0))>0"
      + " OR \(value) GLOB ('*[^'||char(1)||'-'||char(127)||']*')"
  }
}
