import AppKit
import SwiftUI

/// A neutral initial responder: fields and charts remain available to clicks,
/// Tab navigation and VoiceOver, without opening a page in editing mode.
struct RelayInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> RelayInitialFocusView { RelayInitialFocusView() }
    func updateNSView(_ view: RelayInitialFocusView, context: Context) {}
}

final class RelayInitialFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
}

extension View {
    func relayInitialFocus() -> some View {
        background(RelayInitialFocus().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
