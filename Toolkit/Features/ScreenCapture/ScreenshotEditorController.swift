import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Keeps edits local until the user copies or saves the finished screenshot.
@MainActor
final class ScreenshotEditorController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init?(url: URL, onCopy: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        guard let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else { return nil }
        self.onClose = onClose
        let model = ScreenshotEditorModel(image: image, logicalSize: bitmap.size)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Edit Screenshot"
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 800, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(model: model, onCancel: { [weak self] in
            self?.close()
        }, onExport: { [weak self] saveToDesktop in
            do {
                let data = try model.pngData()
                if saveToDesktop {
                    let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let destination = CaptureFiles.uniqueURL(in: desktop, baseName: url.deletingPathExtension().lastPathComponent, pathExtension: "png")
                    try data.write(to: destination, options: .atomic)
                } else {
                    onCopy(data)
                }
                self?.close()
            } catch {
                let alert = NSAlert(error: error)
                if let window = self?.window { alert.beginSheetModal(for: window) }
            }
        }))
        if let screen = NSScreen.main {
            let size = CGSize(width: min(1040, screen.visibleFrame.width - 60), height: min(740, screen.visibleFrame.height - 60))
            window.setContentSize(size)
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

private enum ScreenshotTool: String, CaseIterable {
    case crop = "Crop", arrow = "Arrow", box = "Box"

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        }
    }

    var hint: String {
        switch self {
        case .crop: return "Drag to select the area you want to keep."
        case .arrow: return "Drag toward the detail you want to point out."
        case .box: return "Drag around a detail to frame it."
        }
    }
}

private struct ScreenshotAnnotation {
    let tool: ScreenshotTool
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    var path: Path {
        Path { path in
            if tool == .box {
                path.addRoundedRect(in: CGRect.between(start, end), cornerSize: CGSize(width: lineWidth, height: lineWidth))
            } else {
                let length = hypot(end.x - start.x, end.y - start.y)
                guard length > 0 else { return }
                let radius = min(lineWidth / 2, length * 0.11)
                let headLength = min(lineWidth * 3.5, length * 0.45)
                let headWidth = min(lineWidth * 3, length * 0.75)
                let neck = length - headLength
                var arrow = Path()
                arrow.move(to: CGPoint(x: 0, y: -radius))
                arrow.addLine(to: CGPoint(x: neck, y: -radius))
                arrow.addLine(to: CGPoint(x: neck, y: -headWidth / 2))
                arrow.addLine(to: CGPoint(x: length, y: 0))
                arrow.addLine(to: CGPoint(x: neck, y: headWidth / 2))
                arrow.addLine(to: CGPoint(x: neck, y: radius))
                arrow.addLine(to: CGPoint(x: 0, y: radius))
                arrow.addQuadCurve(to: CGPoint(x: -radius, y: 0), control: CGPoint(x: -radius, y: radius))
                arrow.addQuadCurve(to: CGPoint(x: 0, y: -radius), control: CGPoint(x: -radius, y: -radius))
                arrow.closeSubpath()
                let angle = atan2(end.y - start.y, end.x - start.x)
                path.addPath(arrow, transform: CGAffineTransform(translationX: start.x, y: start.y).rotated(by: angle))
            }
        }
    }
}

private extension CGRect {
    static func between(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

@MainActor
private final class ScreenshotEditorModel: ObservableObject {
    struct State {
        var crop: CGRect
        var annotations: [ScreenshotAnnotation] = []
    }

    static let ink = NSColor(srgbRed: 0.83, green: 0.29, blue: 0.30, alpha: 1)
    let image: CGImage
    let logicalSize: CGSize
    @Published var tool: ScreenshotTool = .arrow
    @Published var state: State
    @Published var pendingCrop: CGRect?
    @Published private var history: [State] = []
    @Published private var future: [State] = []

    init(image: CGImage, logicalSize: CGSize) {
        self.image = image
        self.logicalSize = logicalSize
        state = State(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    var canUndo: Bool { !history.isEmpty || pendingCrop != nil }
    var canRedo: Bool { !future.isEmpty }
    var strokeWidth: CGFloat {
        // Keep a consistent visual weight across Retina captures and large screenshots.
        max(3, min(state.crop.width, state.crop.height) / 220)
    }

    func add(_ annotation: ScreenshotAnnotation) {
        remember()
        state.annotations.append(annotation)
    }

    func applyCrop() {
        guard let crop = pendingCrop else { return }
        remember()
        state.crop = crop.integral.intersection(state.crop)
        pendingCrop = nil
    }

    func undo() {
        if pendingCrop != nil { pendingCrop = nil; return }
        guard let previous = history.popLast() else { return }
        future.append(state)
        state = previous
    }

    func redo() {
        guard let next = future.popLast() else { return }
        pendingCrop = nil
        history.append(state)
        state = next
    }

    private func remember() {
        history.append(state)
        future.removeAll()
    }

    func pngData() throws -> Data {
        applyCrop()
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(Self.ink.cgColor)
        context.setFillColor(Self.ink.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in state.annotations {
            context.setLineWidth(annotation.lineWidth)
            context.addPath(annotation.path.cgPath)
            if annotation.tool == .arrow {
                context.fillPath()
            } else {
                context.strokePath()
            }
        }
        guard let rendered = context.makeImage()?.cropping(to: state.crop) else { throw CocoaError(.fileWriteUnknown) }
        // ImageIO preserves the rendering color profile and the capture's original DPI.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: CGFloat(image.width) / max(1, logicalSize.width) * 72,
            kCGImagePropertyDPIHeight: CGFloat(image.height) / max(1, logicalSize.height) * 72
        ]
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

private struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    let onCancel: () -> Void
    let onExport: (Bool) -> Void
    @State private var draft: ScreenshotAnnotation?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let available = CGSize(width: max(1, geometry.size.width - 64), height: max(1, geometry.size.height - 64))
                let crop = model.state.crop
                let scale = min(available.width / crop.width, available.height / crop.height)
                let size = CGSize(width: crop.width * scale, height: crop.height * scale)
                canvas(size: size, scale: scale)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.tool.symbol)
                Text(model.tool.hint)
                Spacer()
                Text("\(Int(model.state.crop.width)) × \(Int(model.state.crop.height)) px")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy to Clipboard") { onExport(false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Copy the edited screenshot (Return)")
                Button("Save to Desktop") { onExport(true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save the edited screenshot to Desktop (⌘Return)")
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onChange(of: model.tool) { _, _ in draft = nil; model.pendingCrop = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(ScreenshotTool.allCases, id: \.self) { tool in
                    Button { model.tool = tool } label: {
                        Label(tool.rawValue, systemImage: tool.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(model.tool == tool ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(tool.hint)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }
            Divider().frame(height: 22)
            Circle().fill(Color(nsColor: ScreenshotEditorModel.ink)).frame(width: 10, height: 10)
                .help("Soft red annotations")
            HStack(spacing: 12) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo (⇧⌘Z)")
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            if model.pendingCrop != nil {
                Button("Apply Crop") { model.applyCrop() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func canvas(size: CGSize, scale: CGFloat) -> some View {
        Canvas { context, _ in
            let crop = model.state.crop
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -crop.minX, y: -crop.minY)
            context.draw(Image(decorative: model.image, scale: 1), in: CGRect(x: 0, y: 0, width: model.image.width, height: model.image.height))
            for annotation in model.state.annotations + (draft.map { [$0] } ?? []) {
                if annotation.tool == .arrow {
                    context.fill(annotation.path, with: .color(Color(nsColor: ScreenshotEditorModel.ink)))
                } else {
                    context.stroke(annotation.path, with: .color(Color(nsColor: ScreenshotEditorModel.ink)), style: StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            if let selection = model.pendingCrop {
                var shade = Path(crop)
                shade.addRect(selection)
                context.fill(shade, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                context.stroke(Path(selection), with: .color(.white), lineWidth: 1.5 / scale)
                for x in [selection.minX, selection.maxX] {
                    for y in [selection.minY, selection.maxY] {
                        context.fill(Path(ellipseIn: CGRect(x: x - 3 / scale, y: y - 3 / scale, width: 6 / scale, height: 6 / scale)), with: .color(.white))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = imagePoint(value.startLocation, scale: scale)
                let end = imagePoint(value.location, scale: scale)
                if model.tool == .crop {
                    let rect = CGRect.between(start, end)
                    model.pendingCrop = rect.width >= 2 && rect.height >= 2 ? rect : nil
                } else {
                    draft = ScreenshotAnnotation(tool: model.tool, start: start, end: end, lineWidth: model.strokeWidth * (model.tool == .arrow ? 1.8 : 1))
                }
            }
            .onEnded { _ in
                if let draft, hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) >= 3 / scale {
                    if draft.tool != .box || (abs(draft.end.x - draft.start.x) >= 3 / scale && abs(draft.end.y - draft.start.y) >= 3 / scale) {
                        model.add(draft)
                    }
                }
                draft = nil
            })
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Screenshot canvas. \(model.tool.hint)")
    }

    private func imagePoint(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let crop = model.state.crop
        return CGPoint(x: min(crop.maxX, max(crop.minX, crop.minX + point.x / scale)), y: min(crop.maxY, max(crop.minY, crop.minY + point.y / scale)))
    }
}
