import SwiftUI

private nonisolated struct FindActionKey: FocusedValueKey {
  typealias Value = @MainActor () -> Void
}

extension FocusedValues {
  var findAction: (@MainActor () -> Void)? {
    get { self[FindActionKey.self] }
    set { self[FindActionKey.self] = newValue }
  }
}

struct FindCommands: Commands {
  @FocusedValue(\.findAction) private var action
  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button("Find") { action?() }.keyboardShortcut("f").disabled(action == nil)
    }
  }
}
