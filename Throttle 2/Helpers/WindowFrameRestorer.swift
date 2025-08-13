import SwiftUI

#if os(macOS)
import AppKit

/// Least disruptive window frame restorer: applies a default / stored frame once, then saves on resize/move.
struct WindowFrameRestorer: NSViewRepresentable {
    private static let key = "ThrottleMainWindowFrame"
    private static let defaultSize = NSSize(width: 1400, height: 900)
    private static let minSize = NSSize(width: 1000, height: 600)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            applyRestore(to: window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func applyRestore(to window: NSWindow, coordinator: Coordinator) {
        window.minSize = Self.minSize
        if !restoreIfNeeded(window) {
            let f = window.frame
            if f.size.width < Self.minSize.width || f.size.height < Self.minSize.height {
                let newSize = NSSize(width: max(f.size.width, Self.minSize.width),
                                      height: max(f.size.height, Self.minSize.height))
                let newOrigin = NSPoint(x: f.origin.x, y: f.origin.y + (f.size.height - newSize.height))
                window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
            }
        }
        if window.delegate !== coordinator { window.delegate = coordinator }
        coordinator.onFrameChange = { saveFrame(window.frame) }
    }

    private func restoreIfNeeded(_ window: NSWindow) -> Bool {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        let targetRect: NSRect
        if let stored, let rect = rectFromString(stored) {
            targetRect = validated(rect)
        } else {
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: Self.defaultSize.width, height: Self.defaultSize.height)
            var frame = NSRect(origin: screenFrame.origin, size: Self.defaultSize)
            frame.origin.x = screenFrame.midX - frame.size.width/2
            frame.origin.y = screenFrame.midY - frame.size.height/2
            targetRect = frame
        }
        let current = window.frame
        if current.size.width < Self.minSize.width * 0.9 || current.size.height < Self.minSize.height * 0.9 {
            window.setFrame(targetRect, display: true)
            return true
        }
        return false
    }

    private func validated(_ rect: NSRect) -> NSRect {
        var r = rect
        r.size.width = max(r.size.width, Self.minSize.width)
        r.size.height = max(r.size.height, Self.minSize.height)
        if let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.visibleFrame, r) }) ?? NSScreen.main {
            if !NSIntersectsRect(screen.visibleFrame, r) {
                r.origin = screen.visibleFrame.origin
            }
        }
        return r
    }

    private func rectFromString(_ s: String) -> NSRect? {
        let comps = s.split(separator: " ").compactMap { Double($0) }
        guard comps.count == 4 else { return nil }
        return NSRect(x: comps[0], y: comps[1], width: comps[2], height: comps[3])
    }

    private func saveFrame(_ rect: NSRect) {
        let str = "\(Int(rect.origin.x)) \(Int(rect.origin.y)) \(Int(rect.size.width)) \(Int(rect.size.height))"
        UserDefaults.standard.set(str, forKey: Self.key)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var onFrameChange: (() -> Void)?
        func windowDidEndLiveResize(_ notification: Notification) { onFrameChange?() }
        func windowDidMove(_ notification: Notification) { onFrameChange?() }
    }
}
#endif
