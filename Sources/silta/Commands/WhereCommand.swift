import ArgumentParser
import Foundation
import SiltaCore

struct WhereCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "where",
    abstract: "Resolve the workspace, repository and app for a local path.")
  static let workspaceSource = WorkspaceSource.option
  static let dataShape = Shape.object([
    "workspace": .string, "repo": .string, "app": .optional(.string),
    "branch": .any, "head": .string, "confidence": .string, "reason": .string,
    "candidates": .array(.object(["app": .string, "ref": .string])),
  ])

  @OptionGroup var global: GlobalOptions
  @Option(help: "Inspect this directory instead of the current one.") var path: String?
  @Option(help: "Select one of this path's candidate apps.") var app: String?
  @Option(help: "Use this task before session or branch task evidence.") var task: String?
  @Option(
    name: .customLong("set"), help: "Set this worktree's override (human-only when changing it).")
  var setApp: String?
  @Flag(help: "Remove this worktree's override (human-only when changing it).") var unset = false

  var appSlug: String? { app ?? setApp }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    guard !(setApp != nil && unset), !((setApp != nil || unset) && (app != nil || task != nil))
    else {
      throw UsageError.invalid(
        message: "Use --set or --unset alone, without --app or --task.",
        command: "silta where")
    }
    let directory = URL(filePath: path ?? FileManager.default.currentDirectoryPath)
    let service = LocationService(environment: context.environment)
    var approvalUsed = false
    let result: LocationResult
    if setApp != nil || unset {
      (result, approvalUsed) = try await service.override(
        path: directory, workspace: global.ws,
        app: setApp, approved: global.approved)
    } else {
      result = try await service.resolve(
        path: directory, workspace: global.ws, app: app, task: task)
    }
    var text =
      "\(result.workspace) / \(result.repo) / \(result.app ?? "unresolved")"
      + " [\(result.confidence): \(result.reason)]\n"
      + "branch: \(result.branch ?? "(detached)")\nhead: \(result.head)\n"
    if result.confidence == "low" {
      text += "candidates: " + result.candidates.map(\.app).joined(separator: ", ") + "\n"
      if result.candidates.isEmpty {
        text += "next: silta --ws \(shellWord(result.workspace)) ws show\n"
      }
      text += result.candidates.map {
        "next: silta --ws \(shellWord(result.workspace)) where --path \(shellWord(directory.path))"
          + " --app \(shellWord($0.app))\n"
      }.joined()
    }
    let quiet = setApp != nil || unset ? "" : text
    if setApp != nil || unset {
      let receipt: String
      if result.overrideChanged == false {
        receipt = unset ? "No override" : "Override already \(setApp ?? "")"
      } else {
        receipt = "Override \(unset ? "removed" : "set")"
      }
      text = "\(receipt) for \(directory.resolvingSymlinksInPath().path).\n" + text
    }
    return CommandOutput(
      text: text, quiet: quiet, data: result,
      warnings: result.warnings, approvalUsed: approvalUsed
    ).reporting(result.workspace)
  }
}
