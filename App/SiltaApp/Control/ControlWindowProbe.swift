#if DEBUG
  import AppKit
  import Foundation
  import SwiftUI

  struct ControlWindowProbe: NSViewRepresentable {
    let report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe { Probe(report: report) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
      private weak var observedWindow: NSWindow?
      private var isClosing = false
      private let report: (NSWindow?) -> Void

      init(report: @escaping (NSWindow?) -> Void) {
        self.report = report
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
          NotificationCenter.default.removeObserver(
            self, name: NSWindow.didUpdateNotification, object: observedWindow)
          NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: observedWindow)
        }
        observedWindow = window
        isClosing = false
        if let window {
          NotificationCenter.default.addObserver(
            self, selector: #selector(windowUpdated(_:)), name: NSWindow.didUpdateNotification,
            object: window)
          NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification,
            object: window)
        }
        report(window)
      }

      @objc private func windowUpdated(_ notification: Notification) {
        if !isClosing { report(window) }
      }

      @objc private func windowClosing(_ notification: Notification) {
        isClosing = true
        report(nil)
      }
    }
  }
#endif
