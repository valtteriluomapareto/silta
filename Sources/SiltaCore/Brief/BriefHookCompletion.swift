/// Hook output and diagnostics decided together before completion claims the watchdog.
package struct BriefHookCompletion {
  /// Body-free diagnostics, with a process-expiry tag independent of child deadlines.
  package let entry: LogEntry
  /// Silent success on errors or expiry; successful hook output never writes stderr.
  package let rendered: Rendered

  /// The caller supplies expiry from its process deadline; this decision never reads time.
  package init(rendered original: Rendered, entry originalEntry: LogEntry, expired: Bool) {
    var entry = originalEntry
    entry.exitCode = 0
    if expired, !entry.warnings.contains("hook_timeout") { entry.warnings.append("hook_timeout") }
    self.entry = entry
    if expired || original.exitCode != 0 {
      rendered = Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
    } else {
      var output = original
      output.stderr = ""
      rendered = output
    }
  }
}
