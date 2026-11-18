//
//  My_Mac_AppApp.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import AppKit
import SwiftUI

@main
struct ToolkitApp: App {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("ToolkitMainWindow")

    @NSApplicationDelegateAdaptor(ToolkitAppDelegate.self) private var appDelegate
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper)
                .frame(minWidth: 780, minHeight: 540)
                .onAppear {
                    appDelegate.onOpenFiles = { urls in
                        bootstrapper.handleSharedFiles(urls)
                    }
                    appDelegate.onOpenShareURLPaths = { urls in
                        bootstrapper.handleSharedFiles(urls)
                    }
                }
        }
    }
}

struct ToolkitMainWindowObserver: NSViewRepresentable {
    let onFocus: () -> Void

    func makeNSView(context: Context) -> WindowMarker {
        let view = WindowMarker()
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ view: WindowMarker, context: Context) {
        view.onFocus = onFocus
    }

    final class WindowMarker: NSView {
        var onFocus: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            guard let window else { return }
            window.identifier = ToolkitApp.mainWindowIdentifier
            notifications.addObserver(
                self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window
            )
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            onFocus?()
        }
    }
}
