import Foundation

/// Turns a command's result into stdout, stderr and an exit status (spec §16, §20.1).
/// It is the only place that decides which stream gets what.
package enum OutputRouter {
  /// Renders `result` for `mode`. Never throws: an error while rendering a success is
  /// reported as an internal error.
  package static func render(
    _ result: Result<CommandOutput, any Error>, mode: OutputMode
  ) -> Rendered {
    switch result {
    case .success(let output):
      do {
        return try success(output, mode: mode)
      } catch {
        return failure(InternalError(error), mode: mode)
      }
    case .failure(let error as any CodedError):
      return failure(error, mode: mode)
    case .failure(let error):
      return failure(InternalError(error), mode: mode)
    }
  }

  private static func success(_ output: CommandOutput, mode: OutputMode) throws -> Rendered {
    if mode.json {
      let envelope = Envelope(
        ok: true, data: Envelope.AnyData(value: output.data), error: nil,
        warnings: output.warnings)
      return Rendered(
        stdout: try line(envelope), stderr: "", exitCode: 0, errorCode: nil,
        warningCodes: output.warnings.map(\.code))
    }
    let warnings = output.warnings.map { "warning: \($0.message) [\($0.code)]\n" }.joined()
    let shown = mode.quiet ? output.quiet : output.text
    let text = shown.isEmpty ? "" : terminated(shown)
    return Rendered(
      stdout: text, stderr: warnings, exitCode: 0, errorCode: nil,
      warningCodes: output.warnings.map(\.code))
  }

  private static func failure(_ error: any CodedError, mode: OutputMode) -> Rendered {
    let code = error.code
    if mode.json {
      let envelope = Envelope(
        ok: false, data: nil,
        error: EnvelopeFailure(
          code: code.rawValue, message: error.message, next: error.next,
          nextBy: error.nextBy.rawValue, retryAfter: error.retryAfter),
        warnings: [])
      do {
        return Rendered(
          stdout: try line(envelope), stderr: "", exitCode: code.exitCode, errorCode: code)
      } catch {
        // Strings, ints and string arrays always encode, so this is unreachable; it
        // still answers in JSON on stdout as promised.
        return Rendered(
          stdout: unencodableError, stderr: "", exitCode: ErrorCode.env.exitCode,
          errorCode: .env)
      }
    }
    return text(error: error, code: code)
  }

  private static let unencodableError =
    #"{"error":{"code":"env","message":"internal error (bug): error not encodable","#
    + #""next":["silta doctor"],"next_by":"human"},"ok":false,"schema":1,"warnings":[]}"# + "\n"

  private static func text(error: any CodedError, code: ErrorCode) -> Rendered {
    let verb = error.nextBy == .human ? "ask human" : "next"
    var stderr = "error: \(error.message) [\(code.rawValue)]\n"
    if let seconds = error.retryAfter {
      stderr += "retry after: \(seconds)s\n"
    }
    stderr += error.next.map { "\(verb): \($0)\n" }.joined()
    return Rendered(stdout: "", stderr: stderr, exitCode: code.exitCode, errorCode: code)
  }

  private static func line(_ envelope: Envelope) throws -> String {
    try json(envelope) + "\n"
  }

  /// `value` as one line of JSON with sorted keys, the form all output uses.
  static func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let json = String(bytes: try encoder.encode(value), encoding: .utf8) else {
      throw EncodingError.invalidValue(
        value, .init(codingPath: [], debugDescription: "JSONEncoder produced invalid UTF-8"))
    }
    return json
  }

  private static func terminated(_ text: String) -> String {
    text.hasSuffix("\n") ? text : text + "\n"
  }
}
