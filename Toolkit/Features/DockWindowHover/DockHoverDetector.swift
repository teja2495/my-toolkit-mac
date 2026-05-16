import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class DockHoverDetector {
    private var cachedDockProcessIdentifier: pid_t?
    private var cachedDockAXElement: AXUIElement?

    func hoveredApplication(at mouseLocation: CGPoint) -> DockHoveredApplication? {
        guard let dockAXElement = dockElement() else { return nil }

        // NSEvent.mouseLocation uses Cocoa coordinates (bottom-left origin).
        // AXUIElementCopyElementAtPosition expects top-left coordinates in the
        // display space containing the cursor.
        let accessibilityPoint = accessibilityPoint(from: mouseLocation)

        var elementReference: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            dockAXElement,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &elementReference
        )

        guard result == .success, let hoveredElement = elementReference else {
            return nil
        }

        return dockApplication(from: hoveredElement)
    }

    private func dockElement() -> AXUIElement? {
        if
            let cachedDockProcessIdentifier,
            let cachedDockAXElement,
            NSRunningApplication(processIdentifier: cachedDockProcessIdentifier) != nil
        {
            return cachedDockAXElement
        }

        guard let dockApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }

        let dockAXElement = AXUIElementCreateApplication(dockApplication.processIdentifier)
        cachedDockProcessIdentifier = dockApplication.processIdentifier
        cachedDockAXElement = dockAXElement
        return dockAXElement
    }

    private func dockApplication(from sourceElement: AXUIElement) -> DockHoveredApplication? {
        var currentElement: AXUIElement? = sourceElement

        for _ in 0..<8 {
            guard let element = currentElement else { return nil }

            if isApplicationDockItem(element) {
                return resolveRunningApplication(from: element)
            }

            currentElement = parentElement(of: element)
        }

        return nil
    }

    private func isApplicationDockItem(_ element: AXUIElement) -> Bool {
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: element)
        return subrole == "AXApplicationDockItem"
    }

    private func resolveRunningApplication(from element: AXUIElement) -> DockHoveredApplication? {
        let title = stringAttribute(kAXTitleAttribute as String, from: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifierFromURL = urlAttribute("AXURL", from: element)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }

        let runningApplication: NSRunningApplication?
        if let bundleIdentifierFromURL {
            runningApplication = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifierFromURL)
                .first(where: { $0.activationPolicy == .regular })
        } else if let title, !title.isEmpty {
            runningApplication = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && $0.localizedName == title
            })
        } else {
            runningApplication = nil
        }

        guard let runningApplication else { return nil }
        guard let dockItemFrame = frame(of: element) else { return nil }

        return DockHoveredApplication(
            processIdentifier: runningApplication.processIdentifier,
            bundleIdentifier: runningApplication.bundleIdentifier ?? bundleIdentifierFromURL,
            displayName: runningApplication.localizedName ?? title ?? "App",
            dockItemFrame: dockItemFrame
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let positionValue = positionRef,
            let sizeValue = sizeRef,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        // AX returns top-left origin; convert against the screen containing
        // that AX rect so NSPanel placement works across display arrangements.
        return cocoaFrame(fromAccessibilityPosition: position, size: size)
    }

    private func accessibilityPoint(from cocoaPoint: CGPoint) -> CGPoint {
        // AX y=0 is the top of the PRIMARY display; the flip must use the primary
        // screen's height, not the containing screen's height.
        guard let primaryScreen = NSScreen.screens.first else { return cocoaPoint }
        return CGPoint(x: cocoaPoint.x, y: primaryScreen.frame.maxY - cocoaPoint.y)
    }

    private func cocoaFrame(fromAccessibilityPosition position: CGPoint, size: CGSize) -> CGRect {
        // Same reason: AX positions are always relative to the primary display's
        // top-left, so the inverse flip must use the primary screen's height.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: position.x,
            y: primaryMaxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var parentReference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentReference
        )

        guard result == .success else { return nil }

        guard let parentReference else { return nil }
        return unsafeBitCast(parentReference, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }

        if let url = value as? URL {
            return url
        }

        if let urlString = value as? String {
            return URL(string: urlString)
        }

        return nil
    }
}
