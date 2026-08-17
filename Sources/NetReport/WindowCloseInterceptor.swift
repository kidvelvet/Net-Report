//
// Net Report - a macOS application for running a local amateur radio net.
// Copyright (C) 2026  kidvelvet (W7SKW)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import AppKit

/// Makes the main window's red close button quit the app (after the usual
/// confirmation) instead of just hiding the window.
///
/// By default macOS keeps an app running with no windows, so closing Net Report
/// left it alive in the Dock and quitting meant right-clicking its icon. Rather
/// than set `applicationShouldTerminateAfterLastWindowClosed` — which closes the
/// window *first* and would leave the app running windowless if the user
/// cancelled the quit — this intercepts the close itself: the window stays
/// exactly as it was unless the user confirms.
///
/// Attach with `.background(WindowCloseInterceptor())` inside the main window
/// only; auxiliary windows (Announcements, Databases) keep normal close
/// behaviour.
struct WindowCloseInterceptor: NSViewRepresentable {

    func makeCoordinator() -> CloseProxy { CloseProxy() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachingView()
        // Capture only the coordinator: a SwiftUI Context isn't documented to
        // stay valid outside this call, and holding it would drag the whole
        // environment along with it.
        let proxy = context.coordinator
        view.onAttach = { window in
            // Keep whatever delegate SwiftUI installed and forward everything
            // except the one method we care about.
            guard window.delegate !== proxy else { return }
            proxy.forwardee = window.delegate
            window.delegate = proxy
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Hand the window back to SwiftUI's delegate if this view goes away, so the
    /// window is never left with a dangling or absent delegate.
    static func dismantleNSView(_ nsView: NSView, coordinator: CloseProxy) {
        if nsView.window?.delegate === coordinator {
            nsView.window?.delegate = coordinator.forwardee
        }
        coordinator.forwardee = nil
    }
}

/// A view whose only job is to tell us which window it landed in.
private final class WindowAttachingView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach?(window) }
    }
}

/// Window delegate that turns "close the last main window" into "quit the app",
/// forwarding every other delegate message to SwiftUI's own delegate.
final class CloseProxy: NSObject, NSWindowDelegate {
    /// SwiftUI's delegate, which still needs to see everything else.
    ///
    /// Held **strongly** on purpose. `NSWindow.delegate` is a weak property, so
    /// installing this proxy drops the window's only reference to SwiftUI's
    /// delegate. AppKit also caches which optional delegate methods the delegate
    /// answers to at the moment it is installed — so if the forwardee were weak
    /// and later deallocated, AppKit would still send those messages and the
    /// process would die on `doesNotRecognizeSelector:`. `dismantleNSView`
    /// clears this, so the reference can't outlive the view.
    var forwardee: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // With more than one main window open (File ▸ New Net Report Window),
        // closing one should just close it. Identify siblings by the delegate
        // type actually installed on them rather than by title, which any
        // auxiliary window could collide with.
        let siblings = NSApplication.shared.windows.filter {
            $0 !== sender && $0.isVisible && $0.delegate is CloseProxy
        }
        guard siblings.isEmpty else { return true }

        // Ask via the app delegate's confirmation. Returning false leaves the
        // window untouched; if the user confirms, the app terminates anyway.
        NSApplication.shared.terminate(nil)
        return false
    }

    // MARK: - Transparent forwarding

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let forwardee, forwardee.responds(to: aSelector) else { return nil }
        return forwardee
    }
}
