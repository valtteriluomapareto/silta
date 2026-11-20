#if DEBUG
  import Foundation
  import SiltaAppSupport

  nonisolated enum ControlLaunch {
    struct Options {
      let snapshot: URL?
      let runDirectory: URL?
      let route: Route
      let dark: Bool
      let width: Int
      let height: Int

      /// A snapshot or a driver run, whose output must not depend on the human's
      /// stored preferences. A plain `-SiltaFixture` launch is for trying the app by hand.
      var isAutomated: Bool { snapshot != nil || runDirectory != nil }
    }

    struct Route {
      let screen: AppRoute
      let ref: String?
      let documentView: AppDocumentView

      init(_ value: String) throws {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let prefix = parts.first, let screen = AppRoute(rawValue: String(prefix)),
          parts.count == 1 || (screen != .mywork && !parts[1].isEmpty)
        else {
          throw AppLoadFailure(
            message:
              "Use mywork, board[:task-ref], workspace[:edge-, app- or service-ref] or "
              + "docs[:doc-ref[:view]]."
          )
        }
        self.screen = screen
        var selectedRef = parts.count == 2 ? String(parts[1]) : nil
        var documentView: AppDocumentView = .document
        if screen == .docs, let value = selectedRef, let split = value.lastIndex(of: ":"),
          let view = AppDocumentView(rawValue: String(value[value.index(after: split)...]))
        {
          selectedRef = String(value[..<split])
          documentView = view
        }
        guard selectedRef?.isEmpty != true else { throw ControlLaunch.refusal() }
        ref = selectedRef
        self.documentView = documentView
      }

      @MainActor func apply(to model: AppModel) throws {
        if let ref {
          switch screen {
          case .board:
            guard let reader = model.reader, let workspace = model.workspace else {
              throw AppLoadFailure(message: "Load a fixture workspace before selecting a task.")
            }
            model.inspect(task: try reader.task(ref, workspace: workspace).ref)
          case .workspace:
            let map = model.visibleData?.map
            if let connection = map?.connections.first(where: { $0.attachment == ref }) {
              model.select(connection: connection.attachment)
            } else if map?.apps.contains(where: { $0.attachment == ref }) == true
              || map?.services.contains(where: { $0.attachment == ref }) == true
            {
              model.select(node: ref)
            } else {
              throw AppLoadFailure(
                message: "The fixture has no matching connection, app or service.")
            }
          case .docs:
            guard let reader = model.reader, let workspace = model.workspace,
              let document = try reader.document(ref, workspace: workspace).document
            else { throw AppLoadFailure(message: "Choose a fixture document revision.") }
            model.docsAbout = nil
            if document.archived { model.includeArchivedDocuments = true }
            model.select(document: document.ref)
            model.select(documentView: documentView)
          case .mywork: break
          }
        } else {
          model.navigate(to: screen)
        }
      }
    }

    static func parse(_ arguments: [String]) throws -> Options? {
      var values: [String: String] = [:]
      var index = 0
      while index < arguments.count {
        let flag = arguments[index]
        index += 1
        guard flag.hasPrefix("-Silta") else { continue }
        guard values[flag] == nil,
          [
            "-SiltaFixture", "-SiltaSnapshot", "-SiltaRoute", "-SiltaSize", "-SiltaDark",
            "-SiltaRunDirectory",
          ].contains(flag)
        else { throw refusal() }
        if flag == "-SiltaDark" {
          values[flag] = ""
          continue
        }
        guard index < arguments.count, !arguments[index].isEmpty,
          !arguments[index].hasPrefix("-")
        else { throw refusal() }
        values[flag] = arguments[index]
        index += 1
      }
      guard !values.isEmpty else { return nil }
      guard values["-SiltaFixture"] == nil || values["-SiltaFixture"] == "v2" else {
        throw refusal()
      }
      let snapshot = try values["-SiltaSnapshot"].map(snapshotURL)
      guard values["-SiltaFixture"] != nil || snapshot != nil else { throw refusal() }
      let runDirectory = try values["-SiltaRunDirectory"].map { path in
        guard path.hasPrefix("/"), snapshot == nil else { throw refusal() }
        return URL(filePath: path)
      }
      let size = try values["-SiltaSize"].map(parseSize) ?? (1280, 800)
      return Options(
        snapshot: snapshot, runDirectory: runDirectory,
        route: try Route(values["-SiltaRoute"] ?? "mywork"),
        dark: values["-SiltaDark"] != nil, width: size.0, height: size.1)
    }

    private static func snapshotURL(_ value: String) throws -> URL {
      let url = URL(filePath: value).standardizedFileURL
      guard url.pathExtension.lowercased() == "png",
        !["sidebar.png", "inspector.png"].contains(url.lastPathComponent.lowercased())
      else { throw refusal() }
      return url
    }

    private static func parseSize(_ value: String) throws -> (Int, Int) {
      let parts = value.split(separator: "x", omittingEmptySubsequences: false)
      guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
        (1000...4096).contains(width), (700...4096).contains(height)
      else { throw refusal() }
      return (width, height)
    }

    private static func refusal() -> AppLoadFailure {
      AppLoadFailure(
        message: "Use -SiltaFixture v2 or -SiltaSnapshot out.png, "
          + "with optional -SiltaRoute, -SiltaDark and -SiltaSize 1280x800. "
          + "The names sidebar.png and inspector.png are reserved for snapshot parts.")
    }
  }
#endif
