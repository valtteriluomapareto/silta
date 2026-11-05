import ArgumentParser
import SiltaCore

/// Reference grammar, reached through the literal `help refs` route.
struct ReferenceHelpCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "refs", abstract: "Read the reference grammar.",
    usage: "silta help refs [<options>]", version: SiltaVersion.current)
  static let dataShape = Shape.object(["text": .string])
  static let workspaceSource = WorkspaceSource.none
  @OptionGroup var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    CommandOutput(text: Self.text, quiet: Self.text, data: Manual(text: Self.text))
  }

  private struct Manual: Encodable, Sendable { let text: String }

  /// Removes only the two route words; global option values remain opaque.
  static func arguments(in arguments: [String]) -> [String]? {
    var words: [Int] = []
    var skipValue = false
    for (index, argument) in arguments.enumerated() {
      if skipValue {
        skipValue = false
        continue
      }
      if argument == "--" { break }
      if argument == "--ws" || argument == "--approved" {
        skipValue = true
        continue
      }
      if argument.hasPrefix("-") { continue }
      words.append(index)
      if words.count == 2 { break }
    }
    guard words.count == 2, arguments[words[0]] == "help", arguments[words[1]] == "refs" else {
      return nil
    }
    return arguments.enumerated().filter { !words.contains($0.offset) }.map(\.element)
  }

  private static let text = """
    # Reference grammar
    Bare task ids are accepted wherever a task is expected. The same grammar is used in \
    arguments, JSON and [[links]] in bodies. Parsing a reference does not imply its target \
    exists or is supported by a command.

    | Ref | Example | Notes |
    |---|---|---|
    | Task | AC-12 | task:AC-12 is also accepted |
    | Comment | AC-12/3 | the 3rd comment on AC-12 |
    | Doc / revision / comment | doc:mobile-auth-flow, doc:mobile-auth-flow@4, \
    doc:mobile-auth-flow@4/2 | M2 resolution |
    | App, topic | app:platform-api, topic:messaging | |
    | Code | platform-api:src/Api/Controllers/AuthController.cs#L40-52 | code: prefix optional; \
    @<ref> after app selects another branch: platform-api@feature/x:path |
    | Plan lines | plan@3#L12-18, plan#L12 | latest revision when @n is omitted |
    | Diff lines | diff:lib/push/categories.dart#L88, #-L88 | relative to the task review \
    subject; M2 resolution |
    | Note | note:notes/projects/acme/2026-10-26-weekly-status.md | |
    | URL | url:https://dev.azure.com/… | |
    | External party | ext:acme | 1–64 lowercase letters, digits and -, starting/ending \
    alphanumeric; waited on, never an actor |
    """ + "\n"
}
