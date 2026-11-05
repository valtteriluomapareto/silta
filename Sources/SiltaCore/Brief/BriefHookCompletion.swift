/// Hook output and diagnostics decided together before completion claims the watchdog.
/// The watchdog alone owns the process deadline: once it fires, completion never runs.
package struct BriefHookCompletion {
  /// Body-free diagnostics with the hook's exit code.
  package let entry: LogEntry
  /// Silent success on errors; successful hook output never writes stderr.
  package let rendered: Rendered

  /// This decision never reads time.
  package init(rendered original: Rendered, entry originalEntry: LogEntry) {
    var entry = originalEntry
    entry.exitCode = 0
    self.entry = entry
    if original.exitCode != 0 {
      rendered = Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
    } else {
      var output = original
      output.stderr = ""
      rendered = output
    }
  }
}
