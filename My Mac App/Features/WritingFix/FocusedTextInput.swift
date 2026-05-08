import AppKit
import ApplicationServices
import Foundation

struct FocusedTextInput {
    let element: AXUIElement
    let frame: CGRect
    let role: String
    let canSetValue: Bool
    let processIdentifier: pid_t
}

final class FocusedTextInputResolver {
    private let systemWideElement = AXUIElementCreateSystemWide()

    func focusedTextInput() -> FocusedTextInput? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success else {
            return nil
        }

        guard let focusedRef else { return nil }
        let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

        for candidate in editableCandidates(from: focusedElement) {
            guard let input = textInput(from: candidate.element, acceptsGenericValueElement: candidate.isEditableAncestor) else {
                continue
            }

            return input
        }

        return nil
    }

    func text(in input: FocusedTextInput) -> String? {
        stringAttribute(kAXValueAttribute as String, from: input.element)
    }

    func replaceText(in input: FocusedTextInput, with correctedText: String) -> Bool {
        if input.canSetValue {
            let didSetValue = AXUIElementSetAttributeValue(
                input.element,
                kAXValueAttribute as CFString,
                correctedText as CFString
            ) == .success
            if didSetValue {
                setCursorToEndWithDelay(of: input.element)
            }
            return didSetValue
        }

        return pasteReplacement(correctedText, into: input.element)
    }

    func replaceSuffix(in input: FocusedTextInput, suffixLength: Int, with replacement: String) -> Bool {
        guard suffixLength >= 0 else { return false }

        if input.canSetValue {
            guard let text = text(in: input), suffixLength <= text.count else { return false }
            return replaceText(in: input, with: String(text.dropLast(suffixLength)) + replacement)
        }

        _ = AXUIElementSetAttributeValue(input.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<suffixLength {
            sendKey(keyCode: 51, flags: []) // Delete
        }
        pasteString(replacement, restoreCaretIn: nil)
        return true
    }

    func replaceFocusedSuffix(suffixLength: Int, with replacement: String) -> Bool {
        guard suffixLength >= 0 else { return false }

        for _ in 0..<suffixLength {
            sendKey(keyCode: 51, flags: []) // Delete
        }
        pasteString(replacement, restoreCaretIn: nil)
        return true
    }

    func elementAtScreenPoint(_ point: CGPoint) -> AXUIElement? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - point.y

        var elementReference: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(flippedY),
            &elementReference
        )

        guard result == .success else { return nil }
        return elementReference
    }

    func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute as String, from: element)
    }

    private func editableCandidates(from focusedElement: AXUIElement) -> [(element: AXUIElement, isEditableAncestor: Bool)] {
        var candidates: [(AXUIElement, Bool)] = [(focusedElement, false)]

        for attribute in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            guard let editableAncestor = elementAttribute(attribute, from: focusedElement) else { continue }
            if !candidates.contains(where: { isSameElement($0.0, editableAncestor) }) {
                candidates.append((editableAncestor, true))
            }
        }

        var currentParent = elementAttribute(kAXParentAttribute as String, from: focusedElement)
        var depth = 0
        while let parent = currentParent, depth < 8 {
            if !candidates.contains(where: { isSameElement($0.0, parent) }) {
                candidates.append((parent, true))
            }
            currentParent = elementAttribute(kAXParentAttribute as String, from: parent)
            depth += 1
        }

        return candidates
    }

    private func textInput(from element: AXUIElement, acceptsGenericValueElement: Bool) -> FocusedTextInput? {
        guard let role = stringAttribute(kAXRoleAttribute as String, from: element),
              isAllowedEditableRole(role, acceptsGenericValueElement: acceptsGenericValueElement),
              stringAttribute(kAXValueAttribute as String, from: element) != nil,
              let frame = frame(of: element),
              frame.width >= 24,
              frame.height >= 16
        else {
            return nil
        }

        return FocusedTextInput(
            element: element,
            frame: frame,
            role: role,
            canSetValue: isValueSettable(element),
            processIdentifier: processIdentifier(of: element)
        )
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute as String, from: element) else { return false }

        return isAllowedEditableRole(role, acceptsGenericValueElement: false)
    }

    private func isAllowedEditableRole(_ role: String, acceptsGenericValueElement: Bool) -> Bool {
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return true
        case kAXGroupRole, "AXWebArea", kAXUnknownRole:
            return acceptsGenericValueElement
        default:
            return false
        }
    }

    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success else {
            return false
        }

        return settable.boolValue
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
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
            let primaryScreen = NSScreen.screens.first
        else { return nil }

        let cocoaY = primaryScreen.frame.height - position.y - size.height
        return CGRect(x: position.x, y: cocoaY, width: size.width, height: size.height)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t {
        var processIdentifier = pid_t(0)
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier
    }

    private func pasteReplacement(_ replacement: String, into element: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sendKey(keyCode: 0, flags: .maskCommand) // A
        pasteString(replacement, restoreCaretIn: element)
        return true
    }

    private func pasteString(_ string: String, restoreCaretIn element: AXUIElement?) {
        let pasteboard = NSPasteboard.general
        let existingItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)

        sendKey(keyCode: 9, flags: .maskCommand) // V
        if let element {
            setCursorToEndWithDelay(of: element)
        }

        if let existingItems {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                pasteboard.clearContents()
                pasteboard.writeObjects(existingItems)
            }
        }
    }

    private func setCursorToEndWithDelay(of element: AXUIElement) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            moveCaretToEndWithKeyboard(in: element)
        }
    }

    private func moveCaretToEndWithKeyboard(in element: AXUIElement) {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sendKey(keyCode: 124, flags: .maskCommand) // Right Arrow: end of line in most apps
        sendKey(keyCode: 125, flags: .maskCommand) // Down Arrow: end of document in text views
        sendKey(keyCode: 119, flags: []) // End key fallback in controls that support it
    }

    private func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
