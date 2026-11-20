#if DEBUG
  import Observation
  import SiltaAppSupport

  @MainActor struct ControlActions {
    let model: AppModel

    func perform(_ action: ControlAction) async -> ControlOutcome {
      switch action {
      case .navigate(let route):
        guard route != model.route else { return .noop }
        model.navigate(to: route)
      case .select(let value):
        if let result = applySelection(value) { return result }
      case .toggleInspector:
        guard model.route == .board || model.route == .workspace else {
          return .refused(.unavailable)
        }
        model.toggleInspector()
      case .copyRef: return copySelection()
      case .copyCommand: return copyReviewCommand()
      case .refresh:
        let allowDefault = model.route == .docs && model.documentSelection == nil
        let before = Target(model, allowDefaultDocument: allowDefault)
        await model.refresh(force: true).value
        guard before == Target(model, allowDefaultDocument: allowDefault) else {
          return .refused(.superseded)
        }
      }
      let target = Target(model, allowDefaultDocument: model.documentSelection == nil)
      return await settle(target)
    }

    private func applySelection(_ value: String) -> ControlOutcome? {
      let before = Target(model)
      do { try ControlLaunch.Route(value).apply(to: model) } catch {
        return .refused(.unknownSelection)
      }
      return before == Target(model) && status(before) == .accepted ? .noop : nil
    }

    private func copySelection() -> ControlOutcome {
      guard let ref = Target(model).selection?.ref else { return .refused(.unavailable) }
      return .copied(ref)
    }

    private func copyReviewCommand() -> ControlOutcome {
      guard model.route == .board, model.boardInspectorPresented,
        ControlState.readiness(model).phase == "ready",
        let task = model.taskDetail.value, task.ref == model.boardSelection?.taskRef,
        task.status == "review", let workspace = model.workspace,
        let command = model.reader?.commands(forReview: task, workspace: workspace).first
      else { return .refused(.unavailable) }
      return .copied(command.text)
    }

    private func settle(_ target: Target) async -> ControlOutcome {
      let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      defer { changes.continuation.finish() }
      var iterator = changes.stream.makeAsyncIterator()
      while !Task.isCancelled {
        let result = withObservationTracking {
          status(target)
        } onChange: {
          changes.continuation.yield(())
        }
        if let result { return result }
        guard await iterator.next() != nil else { break }
      }
      return .refused(.superseded)
    }

    private func status(_ target: Target) -> ControlOutcome? {
      guard target == Target(model, allowDefaultDocument: target.allowDefaultDocument) else {
        return .refused(.superseded)
      }
      let readiness = ControlState.readiness(model)
      guard readiness.idle else { return nil }
      return readiness.phase == "ready" ? .accepted : .refused(.readFailed)
    }

    private struct Target: Equatable {
      let workspace: String?
      let route: AppRoute
      let selection: ControlState.Selection?
      let inspector: Bool
      let about: String?
      let archived: Bool
      let allowDefaultDocument: Bool

      init(_ model: AppModel, allowDefaultDocument: Bool = false) {
        let navigation = ControlState.navigation(model)
        workspace = model.workspace
        route = model.route
        selection = allowDefaultDocument && route == .docs ? nil : navigation.selection
        inspector = navigation.inspectorOpen
        about = route == .docs ? model.docsAbout : nil
        archived = route == .docs && model.includeArchivedDocuments
        self.allowDefaultDocument = allowDefaultDocument
      }
    }
  }
#endif
