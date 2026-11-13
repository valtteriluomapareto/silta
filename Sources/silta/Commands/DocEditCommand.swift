import ArgumentParser
import Foundation
import SiltaCore

struct DocEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Accept a complete document revision (human-only).",
    discussion: "Use -F for complete UTF-8 Markdown, or --keep-body to retain it.\n"
      + "New docs need --title and --about. About refs replace the whole set.\n"
      + "Input: at most 65536 bytes. Kind stays fixed unless --kind is explicit.\n"
      + "Read editing rules with silta guide recipes.\n"
      + "Create (human): silta doc edit api -F api.md --title API --about app:api\n"
      + "Preserve (human): silta doc edit api --keep-body --about app:api")
  static let dataShape = Shape.object(["ref": .string, "archived": .bool, "changed": .bool])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "Doc slug or doc:slug, without a revision.") var slug: String
  @Option(
    name: .customShort("F"),
    help: .init(
      "Read complete UTF-8 Markdown from a file, or - for stdin; exclusive with --keep-body.",
      valueName: "file"))
  var file: String?
  @Flag(help: "Copy the accepted owned body; exclusive with -F.") var keepBody = false
  @Option(help: "One line of at most 120 characters; required for a new doc, otherwise preserved.")
  var title: String?
  @Option(
    help: "contract, flow, runbook or reference; inferred for a new doc, otherwise preserved.")
  var kind: String?
  @Option(help: "Canonical map ref; repeat to replace the complete set; required for a new doc.")
  var about: [String] = []
  @Flag(help: "Retain detected secrets (human-only).") var allowSecret = false

  var request: DocEditRequest {
    DocEditRequest(
      slug: slug, title: title, kind: kind, about: about.isEmpty ? nil : about,
      allowSecret: allowSecret, keepBody: keepBody)
  }

  func authorize(_ context: CommandContext) throws {
    _ = try service(context).authorizeEdit(request)
  }

  private func service(_ context: CommandContext) -> DocWriteService {
    DocWriteService(
      environment: context.environment, workspace: global.ws, approved: global.approved)
  }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let input: (() throws -> String)? = file.map { file in { try read(file) } }
    let result = try await service(context).edit(request, input: input)
    return CommandOutput(
      text: result.ref + " accepted", quiet: result.ref, data: result,
      warnings: result.warnings, approvalUsed: result.approvalUsed
    ).reporting(result.workspace)
  }

  private func read(_ file: String) throws -> String {
    do {
      let handle =
        try file == "-" ? FileHandle.standardInput : FileHandle(forReadingFrom: URL(filePath: file))
      defer { if file != "-" { try? handle.close() } }  // best-effort close cannot invalidate input
      return try DocInput.read { try handle.read(upToCount: $0) }
    } catch let error as any CodedError { throw error } catch {
      throw UsageError.invalid(message: "Cannot read doc input.", command: "silta doc edit")
    }
  }
}
