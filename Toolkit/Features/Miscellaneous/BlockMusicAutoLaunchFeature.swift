import AppKit
import Foundation
import os

/// Stops macOS from opening Apple Music when the play/pause media key is pressed and no other
/// media app is active. A launch of Music that follows a play/pause key press within a short window
/// is quit right away; opening Music yourself (Dock, Spotlight, Finder) is left alone.
@MainActor
final class BlockMusicAutoLaunchFeature: AppFeature {
    let id = "block-music-autolaunch"

    private static let musicBundleIDs: Set<String> = ["com.apple.Music", "com.apple.iTunes"]
    /// NX_KEYTYPE_PLAY from IOKit's ev_keymap.h.
    private static let playKeyCode = 16
    /// How long after a play/pause press a Music launch counts as key-triggered.
    private static let launchWindow: TimeInterval = 4

    private static let logger = Logger(subsystem: "Toolkit", category: "BlockMusicAutoLaunch")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mediaKeyMonitor: Any?
    private var launchObserver: NSObjectProtocol?
    private var lastPlayKeyPress: Date?

    func start() {
        guard eventTap == nil, mediaKeyMonitor == nil, launchObserver == nil else { return }

        installMediaKeyTap()
        if eventTap == nil {
            // Without a session event tap (no Accessibility access), fall back to a global monitor.
            mediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
                MainActor.assumeIsolated { [weak self] in
                    self?.handleSystemDefined(event)
                }
            }
        }
        Self.logger.notice("Started (event tap: \(self.eventTap != nil), global monitor: \(self.mediaKeyMonitor != nil))")

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { [weak self] in
                self?.handleLaunch(of: app)
            }
        }
    }

    func stop() {
        removeMediaKeyTap()
        if let mediaKeyMonitor {
            NSEvent.removeMonitor(mediaKeyMonitor)
        }
        mediaKeyMonitor = nil
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        lastPlayKeyPress = nil
    }

    private func installMediaKeyTap() {
        let mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let feature = Unmanaged<BlockMusicAutoLaunchFeature>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    feature.handleTap(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func removeMediaKeyTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        handleSystemDefined(nsEvent)
    }

    private func handleSystemDefined(_ event: NSEvent) {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return }
        let keyCode = (event.data1 & 0xFFFF_0000) >> 16
        let isKeyDown = ((event.data1 & 0xFF00) >> 8) == 0xA
        guard keyCode == Self.playKeyCode, isKeyDown else { return }
        lastPlayKeyPress = Date()
        Self.logger.notice("Play/pause key pressed")
    }

    private func handleLaunch(of app: NSRunningApplication?) {
        guard let app,
              let bundleID = app.bundleIdentifier,
              Self.musicBundleIDs.contains(bundleID) else { return }
        let sincePlayKey = lastPlayKeyPress.map { Date().timeIntervalSince($0) }
        Self.logger.notice("Music launched; seconds since play key: \(sincePlayKey ?? -1)")
        guard let sincePlayKey, sincePlayKey <= Self.launchWindow else { return }

        self.lastPlayKeyPress = nil
        app.hide()
        if !app.terminate() || !app.isTerminated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !app.isTerminated {
                    app.forceTerminate()
                }
            }
        }
    }
}
