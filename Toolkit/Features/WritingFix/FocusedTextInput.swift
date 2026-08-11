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

    func selectedText(in input: FocusedTextInput) -> String? {
        stringAttribute(kAXSelectedTextAttribute as String, from: input.element)
    }

    func selectedRange(in input: FocusedTextInput, text: String) -> Range<String.Index>? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            input.element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return Range(NSRange(location: range.location, length: range.length), in: text)
    }

    func replaceSelectedText(in input: FocusedTextInput, with text: String) -> Bool {
        _ = AXUIElementSetAttributeValue(input.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pasteString(text)
        return true
    }

    func replaceText(in input: FocusedTextInput, with correctedText: String) -> Bool {
        // Chrome/web contenteditables often report AXValue as settable, but writing
        // it (or AXSelectedTextRange) desyncs the DOM editing session — text
        // appears updated while typing/caret movement stop working. Paste goes
        // through the real input pipeline and keeps the field editable.
        if input.canSetValue, supportsDirectValueReplacement(input) {
            let didSetValue = AXUIElementSetAttributeValue(
                input.element,
                kAXValueAttribute as CFString,
                correctedText as CFString
            ) == .success
            if didSetValue {
                _ = setCaretToEnd(of: input.element, in: correctedText)
            }
            return didSetValue
        }

        return pasteReplacement(correctedText, into: input.element)
    }

    func replaceSuffix(in input: FocusedTextInput, suffixLength: Int, with replacement: String) -> Bool {
        guard suffixLength >= 0 else { return false }

        if input.canSetValue, supportsDirectValueReplacement(input) {
            guard let text = text(in: input), suffixLength <= text.count else { return false }
            return replaceText(in: input, with: String(text.dropLast(suffixLength)) + replacement)
        }

        _ = AXUIElementSetAttributeValue(input.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<suffixLength {
            sendKey(keyCode: 51, flags: []) // Delete
        }
        pasteString(replacement)
        return true
    }

    func replaceFocusedSuffix(suffixLength: Int, with replacement: String) -> Bool {
        guard suffixLength >= 0 else { return false }

        for _ in 0..<suffixLength {
            sendKey(keyCode: 51, flags: []) // Delete
        }
        pasteString(replacement)
        return true
    }

    func focusedTextByCopying() async -> String? {
        let pasteboard = NSPasteboard.general
        let existingItems = copiedPasteboardItems(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        sendKey(keyCode: 0, flags: .maskCommand) // A
        sendKey(keyCode: 8, flags: .maskCommand) // C

        try? await Task.sleep(nanoseconds: 100_000_000)
        let text = pasteboard.changeCount != previousChangeCount
            ? pasteboard.string(forType: .string)
            : nil
        restorePasteboard(existingItems, to: pasteboard)

        return text?.isEmpty == false ? text : nil
    }

    func replaceFocusedText(with replacement: String) -> Bool {
        sendKey(keyCode: 0, flags: .maskCommand) // A
        pasteString(replacement)
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

    private func supportsDirectValueReplacement(_ input: FocusedTextInput) -> Bool {
        switch input.role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return !isInsideWebContent(input.element)
        default:
            return false
        }
    }

    private func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 24 {
            if stringAttribute(kAXRoleAttribute as String, from: node) == "AXWebArea" {
                return true
            }
            current = elementAttribute(kAXParentAttribute as String, from: node)
            depth += 1
        }
        return false
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
        pasteString(replacement)
        return true
    }

    private func pasteString(_ string: String) {
        let pasteboard = NSPasteboard.general
        let existingItems = copiedPasteboardItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)

        sendKey(keyCode: 9, flags: .maskCommand) // V
        // Do not synthesize Cmd+Down/End after paste — Chrome treats those as
        // page scroll. Paste already leaves the caret after the inserted text.

        if let existingItems {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                restorePasteboard(existingItems, to: pasteboard)
            }
        }
    }

    private func copiedPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]?, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let items {
            pasteboard.writeObjects(items)
        }
    }

    /// Places the caret at the end via Accessibility. Avoids synthetic Cmd+Down /
    /// End keys, which scroll the page in Chrome (e.g. Twitter compose).
    @discardableResult
    private func setCaretToEnd(of element: AXUIElement, in text: String) -> Bool {
        let length = (text as NSString).length
        var range = CFRange(location: length, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
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
