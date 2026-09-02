import AppKit
import AVKit
import MacEaseAppCore
import SwiftUI
import WebKit

struct SystemRoutePicker: NSViewRepresentable {
  func makeNSView(context: Context) -> AVRoutePickerView {
    AVRoutePickerView(frame: .zero)
  }

  func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// A plain-space NSMenu key equivalent steals spaces before the field editor
/// sees them. This local monitor participates after the responder is known and
/// deliberately returns text-input events untouched.
struct SafeSpacePlaybackShortcut: NSViewRepresentable {
  let action: @MainActor () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.start()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.action = action
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var action: @MainActor () -> Bool
    private var monitor: Any?

    init(action: @escaping @MainActor () -> Bool) {
      self.action = action
    }

    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        guard Self.shouldHandleSpace(
          characters: event.charactersIgnoringModifiers,
          modifiers: event.modifierFlags,
          isRepeat: event.isARepeat,
          focusedElementConsumesSpace: Self.focusedElementConsumesSpace(
            NSApp.keyWindow?.firstResponder
          )
        ) else { return event }
        let handled = MainActor.assumeIsolated { [weak self] in
          self?.action() == true
        }
        return handled ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    static func shouldHandleSpace(
      characters: String?,
      modifiers: NSEvent.ModifierFlags,
      isRepeat: Bool,
      focusedElementConsumesSpace: Bool
    ) -> Bool {
      characters == " "
        && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
        && !isRepeat
        && !focusedElementConsumesSpace
    }

    /// SwiftUI text fields use an NSTextView field editor, while WebKit uses
    /// private descendant views. Native controls also own Space when focused.
    /// Walking the public superview chain covers Web login fields without
    /// naming WebKit implementation classes.
    static func focusedElementConsumesSpace(_ responder: NSResponder?) -> Bool {
      if responder is NSTextView || responder is NSControl { return true }
      var view = responder as? NSView
      while let current = view {
        if current is WKWebView { return true }
        view = current.superview
      }
      return false
    }
  }
}
