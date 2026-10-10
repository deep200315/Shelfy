import AppKit
import SwiftUI

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", symbol: String? = nil, enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    func submenu(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let sub = NSMenu(title: title)
        build(sub)
        item.submenu = sub
        addItem(item)
    }
}

// MARK: - Drag source

/// Transparent AppKit view that handles clicks, double-clicks, context menus and multi-item drags.
final class DragSourceView: NSView, NSDraggingSource {
    var items: () -> [ShelfItem] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }
    var onDragEnded: ([ShelfItem], NSDragOperation) -> Void = { _, _ in }

    private var mouseDownEvent: NSEvent?
    private var dragged: [ShelfItem] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onDoubleClick()
        } else {
            mouseDownEvent = event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        mouseDownEvent = nil

        let list = items()
        guard !list.isEmpty else { return }
        dragged = list
        let origin = convert(down.locationInWindow, from: nil)
        let draggingItems: [NSDraggingItem] = list.enumerated().compactMap { index, item in
            guard let writer = PB.writer(for: item) else { return nil }
            let di = NSDraggingItem(pasteboardWriter: writer)
            let image = Thumbnails.shared.image(for: item)
            let offset = CGFloat(min(index, 6)) * 4
            di.setDraggingFrame(NSRect(x: origin.x - 28 + offset, y: origin.y - 28 - offset, width: 56, height: 56),
                                contents: image)
            return di
        }
        let session = beginDraggingSession(with: draggingItems, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick(event.modifierFlags) }
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .generic] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let list = dragged
        dragged = []
        onDragEnded(list, operation)
    }
}

struct DragSource: NSViewRepresentable {
    var items: () -> [ShelfItem]
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menu: () -> NSMenu? = { nil }
    var onDragEnded: ([ShelfItem], NSDragOperation) -> Void = { _, _ in }

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.items = items
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuProvider = menu
        view.onDragEnded = onDragEnded
    }
}

// MARK: - Drop zone

/// Accepts drops directly (used for Instant Actions and the notch).
class DropZoneView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onDrop: ([ShelfItem]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(PB.readTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover(true)
        Feedback.enter()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(false)
        Feedback.drop()
        let handler = onDrop
        PB.read(sender.draggingPasteboard) { items in if !items.isEmpty { handler(items) } }
        return true
    }
}

struct DropZone: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onDrop: ([ShelfItem]) -> Void

    func makeNSView(context: Context) -> DropZoneView { DropZoneView(frame: .zero) }

    func updateNSView(_ view: DropZoneView, context: Context) {
        view.onHover = onHover
        view.onDrop = onDrop
    }
}

// MARK: - Window drag area

/// Lets the shelf header move the window; double-click runs an action.
final class WindowDragView: NSView {
    var onDoubleClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick(); return }
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }
}

struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}
    var menu: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }

    func updateNSView(_ view: WindowDragView, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.menuProvider = menu
    }
}

// MARK: - Hover tracking

/// Reports pointer enter/exit even when Shelfy isn't the active app (shelves float over other apps,
/// where SwiftUI's onHover stays silent). Invisible to clicks.
final class HoverTrackingView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    private func set(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        onHover(value)
    }
}

struct HoverTracker: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }
    func updateNSView(_ view: HoverTrackingView, context: Context) { view.onHover = onHover }
}

extension View {
    /// Hover that works in a non-activating floating panel.
    func onPanelHover(_ action: @escaping (Bool) -> Void) -> some View {
        overlay(HoverTracker(onHover: action))
    }
}
