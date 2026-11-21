import SiltaAppSupport
import SwiftUI

/// The human creates a todo task and can copy a prompt to hand it to an agent. The app only
/// copies the prompt and never launches an agent (D4).
struct NewTaskSheet: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var task = AppNewTask(title: "")
  @State private var copyPrompt = true
  @FocusState private var titleFocused: Bool

  private var target: ActionTarget? { model.target(AppModel.newTaskTarget) }
  private var sending: Bool { target.map { model.actions.isSending($0) } ?? false }
  private var apps: [AppMapApp] { model.visibleData?.map?.apps ?? [] }
  private var parents: [AppTask] {
    let board = model.visibleData?.snapshot?.board
    return ((board?.todo ?? []) + (board?.doing ?? [])).sorted { $0.ref < $1.ref }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("New task in " + (model.workspaceName ?? "")).font(.system(size: 17, weight: .bold))
        Text("Your tasks go straight to Todo. An agent picks them up by priority.")
          .font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
      }
      field("Title") {
        TextField("What should get done?", text: $task.title).textFieldStyle(.roundedBorder)
          .focused($titleFocused)
      }
      HStack(alignment: .top, spacing: 16) {
        field("App") {
          Picker("App", selection: $task.app) {
            Text("None or the parent's").tag(String?.none)
            ForEach(apps, id: \.slug) { app in
              Text(app.slug).tag(String?.some(app.slug))
            }
          }.labelsHidden()
        }
        field("Priority") {
          Picker("Priority", selection: $task.priority) {
            Text("1 · High").tag(1)
            Text("2").tag(2)
            Text("3 · Low").tag(3)
          }.pickerStyle(.segmented).labelsHidden()
        }
      }
      field("Description · Markdown") {
        TextEditor(text: $task.description).frame(minHeight: 60).scrollContentBackground(.hidden)
          .padding(6).background(Color("Card"), in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color("Ink").opacity(0.12)))
      }
      field("Acceptance · optional") {
        TextEditor(text: $task.acceptance).frame(minHeight: 44).scrollContentBackground(.hidden)
          .padding(6).background(Color("Card"), in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color("Ink").opacity(0.12)))
      }
      field("Parent") {
        Picker("Parent", selection: $task.parent) {
          Text("None").tag(String?.none)
          ForEach(parents, id: \.ref) { parent in
            Text(parent.ref + " " + parent.title).tag(String?.some(parent.ref))
          }
        }.labelsHidden()
      }
      if let failure = target.flatMap({ model.actions.failures[$0] }) {
        ActionFailureView(failure: failure)
      }
      Divider()
      HStack {
        Toggle("Copy agent prompt after creating", isOn: $copyPrompt).toggleStyle(.checkbox)
          .font(.system(size: 12))
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(sending ? "Creating…" : "Create task") { create() }
          .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
          .disabled(!NewTaskForm.canCreate(task) || sending)
      }
    }.padding(22).frame(width: 560).onAppear { titleFocused = true }
  }

  private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 12, weight: .semibold))
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func create() {
    let request = NewTaskForm.trimmed(task)
    Task {
      await model.createTask(request, copyPrompt: copyPrompt)?.value
      if let target, model.actions.failures[target] == nil { dismiss() }
    }
  }
}

/// The sheet's rules, apart from its view.
nonisolated enum NewTaskForm {
  static func canCreate(_ task: AppNewTask) -> Bool {
    !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func trimmed(_ task: AppNewTask) -> AppNewTask {
    var task = task
    task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    task.description = task.description.trimmingCharacters(in: .whitespacesAndNewlines)
    task.acceptance = task.acceptance.trimmingCharacters(in: .whitespacesAndNewlines)
    return task
  }
}

/// Confirms a created task and the prompt copied for it, then fades.
struct CreatedTaskToast: View {
  @Bindable var model: AppModel

  var body: some View {
    if let ref = model.createdTask {
      VStack(alignment: .leading, spacing: 6) {
        Label(
          "Created " + ref + (model.createdPrompt == nil ? "" : " · agent prompt copied"),
          systemImage: "checkmark.circle.fill"
        ).font(.system(size: 13, weight: .semibold))
        if let prompt = model.createdPrompt {
          Text(prompt).font(.system(size: 11, design: .monospaced)).lineLimit(3)
            .foregroundStyle(Color("SecondaryInk"))
        }
      }.padding(14).frame(maxWidth: 520, alignment: .leading)
        .background(Color("Card"), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color("Ink").opacity(0.1)))
        .padding(.bottom, 24)
        .task(id: ref) {
          do { try await Task.sleep(for: .seconds(6)) } catch { return }
          model.createdTask = nil
          model.createdPrompt = nil
        }
        .accessibilityElement(children: .combine)
    }
  }
}
