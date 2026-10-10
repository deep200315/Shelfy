import AppKit
import Combine
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Panel

final class ShelfPanel: NSPanel {
    weak var controller: ShelfWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller
        panel.delegate = controller
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Container (drop target + background)

final class ShelfContainerView: NSView {
    private let shelf: Shelf
    private let hosting: NSHostingView<ShelfView>
    weak var controller: ShelfWindowController?

    init(shelf: Shelf) {
        self.shelf = shelf
        hosting = NSHostingView(rootView: ShelfView(shelf: shelf))
        super.init(frame: NSRect(origin: .zero, size: ShelfWindowController.compactSize))

        // The glass sits inside a transparent margin so its soft shadow can fade out
        // instead of being clipped at the window's square edge.
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        hosting.sizingOptions = []
        hosting.frame = inner
        hosting.autoresizingMask = [.width, .height]

        if #available(macOS 26, *), ProcessInfo.processInfo.environment["SHELFY_NO_GLASS"] == nil {
            let glass = NSGlassEffectView(frame: inner)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = Self.cornerRadius
            hosting.frame = glass.bounds
            glass.contentView = hosting
            addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: inner)
            effect.autoresizingMask = [.width, .height]
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
            addSubview(effect)
            addSubview(hosting)
        }

        registerForDraggedTypes(PB.readTypes)
    }

    static let cornerRadius: CGFloat = 18
    /// Transparent space around the glass, inside the window.
    static let margin: CGFloat = 18

    required init?(coder: NSCoder) { nil }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }

    private func isFromThisShelf(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView)?.window === window
    }

    /// Where a drop would land in the detail list (nil in the compact view: append).
    private func insertionIndex(_ sender: NSDraggingInfo) -> Int? {
        guard shelf.expanded else { return nil }
        let point = hosting.convert(sender.draggingLocation, from: nil)
        let yFromTop = hosting.isFlipped ? point.y : hosting.bounds.height - point.y  // SwiftUI global space is top-left
        return shelf.items.firstIndex { (shelf.rowFrames[$0.id]?.midY ?? .infinity) > yFromTop } ?? shelf.items.count
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        if isFromThisShelf(sender) {
            // Dragging within the shelf reorders, but only in the detail list.
            guard shelf.expanded else {
                shelf.dropIndex = nil
                return []
            }
            shelf.dropIndex = insertionIndex(sender)
            return .generic
        }
        shelf.dropIndex = insertionIndex(sender)
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = operation(for: sender)
        if !isFromThisShelf(sender) {
            shelf.isTargeted = true
            Feedback.enter()
        }
        controller?.pointerEntered()
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shelf.isTargeted = false
        shelf.dropIndex = nil
        // Moving onto an Instant Action tile also "exits" this view; keep the grid while inside the shelf.
        if let frame = window?.frame, !frame.contains(NSEvent.mouseLocation) { shelf.showInstantActions = false }
        controller?.pointerExited()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        shelf.showInstantActions = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shelf.isTargeted = false
        let index = shelf.dropIndex
        shelf.dropIndex = nil
        if isFromThisShelf(sender) {
            guard let index else { return false }
            controller?.noteInternalDrop()
            withAnimation(.spring(duration: 0.3)) { shelf.move(ids: shelf.selection, to: index) }
            Feedback.tick()
            return true
        }
        Feedback.drop()
        PB.read(sender.draggingPasteboard) { [weak shelf] items in shelf?.add(items, at: index) }
        controller?.pointerExited()
        return true
    }
}

// MARK: - Controller

final class ShelfWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    enum Edge { case left, right }
    enum InstantAction { case airDrop, messages, mail, zip, text }

    let shelf: Shelf
    private var previewURLs: [URL] = []
    private var lastClicked: UUID?
    private var dockTimer: Timer?
    private var dockEdge: Edge?
    private var animating = false
    private static let peekWidth: CGFloat = 16 + ShelfContainerView.margin
    static let compactSize = NSSize(width: 210 + 2 * ShelfContainerView.margin, height: 214 + 2 * ShelfContainerView.margin)
    static let expandedSize = NSSize(width: 320 + 2 * ShelfContainerView.margin, height: 400 + 2 * ShelfContainerView.margin)
    private var cancellables = Set<AnyCancellable>()
    /// Set when a drag from this shelf was dropped back onto it (a reorder), so dragEnded ignores it.
    private var internalDrop = false

    init(shelf: Shelf) {
        self.shelf = shelf
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Liquid Glass draws its own edge and shadow; a window shadow on top shows as a dark rim.
        if #available(macOS 26, *) { panel.hasShadow = false } else { panel.hasShadow = true }
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let container = ShelfContainerView(shelf: shelf)
        panel.contentView = container
        super.init(window: panel)

        panel.delegate = self
        panel.controller = self
        container.controller = self
        shelf.controller = self

        shelf.$expanded.removeDuplicates().dropFirst()
            .sink { [weak self] expanded in self?.resize(expanded: expanded) }
            .store(in: &cancellables)
        shelf.$items
            .sink { [weak shelf] items in if items.isEmpty, shelf?.expanded == true { shelf?.expanded = false } }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { nil }

    /// Grows into the detail list (or shrinks back), keeping the top edge in place.
    private func resize(expanded: Bool) {
        if !expanded {
            shelf.selection = []
            shelf.renamingID = nil
        }
        let size = expanded ? Self.expandedSize : Self.compactSize
        var f = panel.frame
        f.origin.y = f.maxY - size.height
        f.origin.x += (f.width - size.width) / 2
        f.size = size
        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame, dockEdge == nil {
            f.origin.x = min(max(f.origin.x, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = max(f.origin.y, vf.minY + 8)
        }
        animating = true
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(f, display: true)
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                self.animating = false
                self.shelf.frameString = NSStringFromRect(self.panel.frame)
                if self.dockEdge != nil { self.slide(out: !self.panel.frame.contains(NSEvent.mouseLocation)) }
            })
    }

    var panel: ShelfPanel { window as! ShelfPanel }

    // MARK: Presentation

    func present(_ placement: Placement) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        var origin: NSPoint
        switch placement {
        case .centered(let p):
            origin = NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        case .below(let p):
            origin = NSPoint(x: p.x - size.width / 2, y: p.y - size.height - 6)
        case .corner:
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let offset = CGFloat((shelf.store?.openShelves.count ?? 1) - 1) * 24
            origin = NSPoint(x: vf.maxX - size.width - 20 - offset, y: vf.maxY - size.height - 20 - offset)
        case .restore:
            if let s = shelf.frameString {
                let saved = NSRectFromString(s)
                let f = NSRect(x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) {
                    panel.setFrame(f, display: true)
                    panel.orderFrontRegardless()
                    return
                }
            }
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        animating = true
        panel.setFrameOrigin(origin)
        animating = false
        shelf.frameString = NSStringFromRect(panel.frame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func bringToFront() {
        if dockEdge != nil { slide(out: false) }
        panel.orderFrontRegardless()
    }

    func moveTo(center point: NSPoint) {
        dockEdge = nil
        shelf.isDocked = false
        present(.centered(point))
    }

    func closeShelf() {
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        shelf.store?.close(shelf)
        shelf.expanded = false
        shelf.showInstantActions = false
    }

    // MARK: Docking at screen edges

    func windowDidMove(_ notification: Notification) {
        guard !animating else { return }
        shelf.frameString = NSStringFromRect(panel.frame)
        dockTimer?.invalidate()
        dockTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.evaluateDock() }
    }

    func windowDidResize(_ notification: Notification) {
        if !animating { shelf.frameString = NSStringFromRect(panel.frame) }
    }

    private func evaluateDock() {
        if NSEvent.pressedMouseButtons & 1 != 0 {  // still dragging the window
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.evaluateDock() }
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, s = screen.frame
        if f.maxX >= s.maxX - 2 {
            dock(.right)
        } else if f.minX <= s.minX + 2 {
            dock(.left)
        } else {
            dockEdge = nil
            shelf.isDocked = false
        }
    }

    func dock(_ edge: Edge) {
        dockEdge = edge
        shelf.isDocked = true
        if !panel.frame.contains(NSEvent.mouseLocation) { slide(out: true) }
    }

    func undock() {
        guard let edge = dockEdge, let screen = panel.screen ?? NSScreen.main else { return }
        dockEdge = nil
        shelf.isDocked = false
        var f = panel.frame
        f.origin.x = edge == .right ? screen.frame.maxX - f.width - 60 : screen.frame.minX + 60
        animate(to: f)
    }

    private func slide(out: Bool) {
        guard let edge = dockEdge, let screen = panel.screen ?? NSScreen.main else { return }
        var f = panel.frame
        let s = screen.frame
        switch (edge, out) {
        case (.right, true): f.origin.x = s.maxX - Self.peekWidth
        case (.right, false): f.origin.x = s.maxX - f.width
        case (.left, true): f.origin.x = s.minX - f.width + Self.peekWidth
        case (.left, false): f.origin.x = s.minX
        }
        animate(to: f)
    }

    private func animate(to frame: NSRect) {
        animating = true
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            },
            completionHandler: { [weak self] in
                self?.animating = false
            })
    }

    func pointerEntered() {
        if dockEdge != nil { slide(out: false) }
    }

    func pointerExited() {
        guard dockEdge != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.dockEdge != nil,
                !self.panel.frame.contains(NSEvent.mouseLocation),
                !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible)
            else { return }
            self.slide(out: true)
        }
    }

    // MARK: Selection

    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
        } else if modifiers.contains(.shift), let last = lastClicked,
            let a = shelf.items.firstIndex(where: { $0.id == last }),
            let b = shelf.items.firstIndex(where: { $0.id == item.id })
        {
            shelf.selection = Set(shelf.items[min(a, b)...max(a, b)].map(\.id))
        } else {
            shelf.selection = [item.id]
        }
        lastClicked = item.id
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { refreshPreview() }
    }

    func itemsForDrag(startingAt item: ShelfItem) -> [ShelfItem] {
        if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
        return shelf.selectedItems
    }

    func noteInternalDrop() { internalDrop = true }

    func dragEnded(_ dragged: [ShelfItem], operation: NSDragOperation) {
        if internalDrop {
            internalDrop = false
            return
        }
        guard !dragged.isEmpty, operation != [] else { return }
        let draggedAll = Set(dragged.map(\.id)) == Set(shelf.items.map(\.id))
        if operation.contains(.move) || operation.contains(.delete) {
            // The files were moved elsewhere; their old paths are no longer valid.
            let ids = Set(dragged.filter { $0.kind == .file }.map(\.id))
            shelf.items.removeAll { ids.contains($0.id) }
            shelf.selection.subtract(ids)
        }
        guard !shelf.pinned else { return }
        if shelf.items.isEmpty || (draggedAll && Settings.shared.closeAfterDragAll) { closeShelf() }
    }

    func removeSelected() {
        shelf.remove(ids: shelf.selection)
    }

    // MARK: Item operations

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file: if let url = item.fileURL { NSWorkspace.shared.open(url) }
        case .link: if let url = item.linkURL { NSWorkspace.shared.open(url) }
        case .text: quickLook()
        }
    }

    func reveal(_ items: [ShelfItem]) {
        let urls = Actions.fileURLs(items)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Starts inline renaming in the detail list.
    func rename(_ item: ShelfItem) {
        guard item.kind == .file else { return }
        shelf.selection = [item.id]
        shelf.expanded = true
        panel.makeKey()
        shelf.renamingID = item.id
    }

    func commitRename(_ item: ShelfItem, to newName: String) {
        shelf.renamingID = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = item.fileURL, !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            if let i = shelf.items.firstIndex(where: { $0.id == item.id }) {
                Thumbnails.shared.invalidate(url.path)
                shelf.items[i].path = dest.path
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func renameShelf() {
        if let name = prompt(title: "Name this shelf", value: shelf.name, button: "Save") { shelf.name = name }
    }

    private func prompt(title: String, value: String, button: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func share(_ items: [ShelfItem]) {
        guard let view = panel.contentView else { return }
        let point = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: Actions.shareables(items))
        picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    /// Runs work off the main thread with a progress label, then adds and selects the results.
    func perform(_ label: String, _ work: @escaping () -> [ShelfItem]) {
        shelf.busy = label
        Actions.queue.async { [weak self] in
            let results = work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.shelf.busy = nil
                let added = self.shelf.add(results)
                if !added.isEmpty { self.shelf.selection = Set(added.map(\.id)) }
            }
        }
    }

    func extractText(_ items: [ShelfItem]) {
        perform("Recognizing text…") {
            let text = Actions.extractText(items)
            guard !text.isEmpty else { return [] }
            DispatchQueue.main.async { PB.copy([.text(text)]) }
            return [.text(text)]
        }
    }

    func instant(_ action: InstantAction, _ items: [ShelfItem]) {
        shelf.showInstantActions = false
        switch action {
        case .airDrop: Actions.perform(.sendViaAirDrop, items)
        case .messages: Actions.perform(.composeMessage, items)
        case .mail: Actions.perform(.composeEmail, items)
        case .zip:
            let urls = Actions.fileURLs(items)
            perform("Compressing…") { Actions.zip(urls).map { [.file($0, owned: true)] } ?? [] }
        case .text: extractText(items)
        }
    }

    // MARK: Menus

    func showCommandBar() {
        CommandBarController.show(entries: CommandEntry.entries(from: actionsMenu()), over: panel)
    }

    func showActionsMenu() {
        actionsMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func showColorMenu() {
        let menu = NSMenu()
        addColorItems(to: menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addColorItems(to menu: NSMenu) {
        for (i, name) in ShelfColor.names.enumerated() {
            let item = ClosureMenuItem(name) { [weak self] in self?.shelf.colorIndex = i }
            item.state = shelf.colorIndex == i ? .on : .off
            if i > 0 {
                item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [ShelfColor.nsColors[i]]))
            }
            menu.addItem(item)
        }
    }

    func menu(for item: ShelfItem) -> NSMenu {
        if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
        let targets = shelf.selectedItems
        let menu = NSMenu()
        menu.addItem(
            ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in targets.forEach { self?.open($0) } })
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { [weak self] in self?.quickLook() })
        if !Actions.fileURLs(targets).isEmpty {
            menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { [weak self] in self?.reveal(targets) })
        }
        if targets.count == 1, targets[0].kind == .file {
            menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") { [weak self] in self?.rename(targets[0]) })
        }
        menu.addItem(.separator())
        addItemActions(to: menu, targets)
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Remove from Shelf", symbol: "minus.circle") { [weak self] in
                self?.shelf.remove(ids: Set(targets.map(\.id)))
            })
        return menu
    }

    func actionsMenu() -> NSMenu {
        let targets = shelf.selectedOrAll
        let menu = NSMenu()
        if !targets.isEmpty {
            let header = NSMenuItem(
                title: shelf.selection.isEmpty ? "All \(targets.count) Items" : "\(targets.count) Selected",
                action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            addItemActions(to: menu, targets)
            menu.addItem(.separator())
        }
        menu.addItem(
            ClosureMenuItem(CommandBarController.menuTitle, key: "k", symbol: "command") { [weak self] in
                self?.showCommandBar()
            })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename Shelf…", symbol: "character.cursor.ibeam") { [weak self] in self?.renameShelf() })
        menu.submenu("Color", symbol: "paintpalette") { addColorItems(to: $0) }
        menu.addItem(
            ClosureMenuItem(shelf.pinned ? "Unpin Shelf" : "Pin Shelf", symbol: shelf.pinned ? "pin.slash" : "pin") {
                [weak self] in
                self?.shelf.pinned.toggle()
            })
        if dockEdge != nil {
            menu.addItem(
                ClosureMenuItem("Undock", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in self?.undock() })
        } else {
            menu.submenu("Dock to Edge", symbol: "sidebar.right") { sub in
                sub.addItem(ClosureMenuItem("Left Edge") { [weak self] in self?.dockNow(.left) })
                sub.addItem(ClosureMenuItem("Right Edge") { [weak self] in self?.dockNow(.right) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Select All", key: "a", enabled: !shelf.items.isEmpty) { [weak self] in
                guard let self else { return }
                self.shelf.selection = Set(self.shelf.items.map(\.id))
            })
        menu.addItem(
            ClosureMenuItem("Clear Shelf", symbol: "trash", enabled: !shelf.items.isEmpty) { [weak self] in
                guard let self else { return }
                self.shelf.remove(ids: Set(self.shelf.items.map(\.id)))
            })
        menu.addItem(ClosureMenuItem("Close Shelf", key: "w", symbol: "xmark") { [weak self] in self?.closeShelf() })
        return menu
    }

    private func dockNow(_ edge: Edge) {
        dockEdge = edge
        shelf.isDocked = true
        slide(out: true)
    }

    private func addItemActions(to menu: NSMenu, _ targets: [ShelfItem]) {
        let files = Actions.fileURLs(targets)
        let images = Actions.imageURLs(targets)

        if addSuggestions(to: menu, targets) { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Share…", symbol: "square.and.arrow.up") { [weak self] in self?.share(targets) })
        menu.addItem(ClosureMenuItem("AirDrop", symbol: "airplayaudio") { Actions.perform(.sendViaAirDrop, targets) })
        menu.addItem(ClosureMenuItem("Copy", key: "c", symbol: "doc.on.doc") { PB.copy(targets) })
        if !files.isEmpty {
            menu.addItem(ClosureMenuItem("Save Copies To…", symbol: "square.and.arrow.down") { Actions.saveCopies(files) })
            menu.addItem(
                ClosureMenuItem("Create ZIP Archive", symbol: "doc.zipper") { [weak self] in
                    self?.perform("Compressing…") { Actions.zip(files).map { [.file($0, owned: true)] } ?? [] }
                })
        }
        if !images.isEmpty {
            menu.submenu("Convert Images", symbol: "photo.on.rectangle.angled") { sub in
                for (label, type) in [("PNG", UTType.png), ("JPEG", .jpeg), ("HEIC", .heic), ("TIFF", .tiff)] {
                    sub.addItem(
                        ClosureMenuItem("To \(label)") { [weak self] in
                            self?.perform("Converting…") { Actions.convert(images, to: type).map { .file($0, owned: true) } }
                        })
                }
            }
            menu.submenu("Resize Images", symbol: "arrow.down.right.and.arrow.up.left") { sub in
                for (label, scale) in [("50%", 0.5), ("25%", 0.25)] {
                    sub.addItem(
                        ClosureMenuItem(label) { [weak self] in
                            self?.perform("Resizing…") { Actions.resize(images, scale: scale).map { .file($0, owned: true) } }
                        })
                }
                sub.addItem(.separator())
                for px in [2048, 1024, 512] {
                    sub.addItem(
                        ClosureMenuItem("Max \(px) px") { [weak self] in
                            self?.perform("Resizing…") { Actions.resize(images, maxPixel: px).map { .file($0, owned: true) } }
                        })
                }
            }
        }
        if Actions.textSourceCount(targets) > 0 {
            menu.addItem(ClosureMenuItem("Extract Text", symbol: "text.viewfinder") { [weak self] in self?.extractText(targets) })
        }

        menu.submenu("Run Shortcut", symbol: "square.2.layers.3d") { sub in
            if Actions.shortcutNames.isEmpty {
                let none = NSMenuItem(title: "No Shortcuts Found", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            }
            for name in Actions.shortcutNames {
                sub.addItem(
                    ClosureMenuItem(name) { [weak self] in
                        self?.perform("Running “\(name)”…") {
                            let out = Actions.runShortcut(name, files).trimmingCharacters(in: .whitespacesAndNewlines)
                            return out.isEmpty ? [] : [.text(out)]
                        }
                    })
            }
        }
        Actions.refreshShortcuts()

        menu.submenu("Custom Scripts", symbol: "terminal") { sub in
            for script in Actions.scripts() {
                sub.addItem(
                    ClosureMenuItem(script.deletingPathExtension().lastPathComponent) { [weak self] in
                        self?.perform("Running script…") { Actions.runScript(script, files) }
                    })
            }
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem("Open Scripts Folder") { NSWorkspace.shared.open(Actions.scriptsDir) })
        }
    }

    /// Actions that only make sense for what's on the shelf. Returns whether any were added.
    private func addSuggestions(to menu: NSMenu, _ targets: [ShelfItem]) -> Bool {
        let images = Actions.urls(targets, conformingTo: .image)
        let pdfs = Actions.urls(targets, conformingTo: .pdf)
        let videos = Actions.urls(targets, conformingTo: .movie)
        var items: [NSMenuItem] = []

        if images.count >= 2 {
            items.append(
                ClosureMenuItem("Stitch Images Vertically", symbol: "rectangle.split.1x2") { [weak self] in
                    self?.perform("Stitching…") { Actions.stitch(images, vertical: true).map { [.file($0, owned: true)] } ?? [] }
                })
            items.append(
                ClosureMenuItem("Stitch Images Side by Side", symbol: "rectangle.split.2x1") { [weak self] in
                    self?.perform("Stitching…") { Actions.stitch(images, vertical: false).map { [.file($0, owned: true)] } ?? [] }
                })
        }
        if !images.isEmpty {
            items.append(
                ClosureMenuItem("Make PDF from Image\(images.count == 1 ? "" : "s")", symbol: "doc.richtext") { [weak self] in
                    self?.perform("Making PDF…") { Actions.imagesToPDF(images).map { [.file($0, owned: true)] } ?? [] }
                })
        }
        if pdfs.count >= 2 {
            items.append(
                ClosureMenuItem("Merge \(pdfs.count) PDFs", symbol: "doc.on.doc") { [weak self] in
                    self?.perform("Merging PDFs…") { Actions.mergePDFs(pdfs).map { [.file($0, owned: true)] } ?? [] }
                })
        }
        if !videos.isEmpty {
            items.append(
                ClosureMenuItem("Make GIF", symbol: "photo.stack") { [weak self] in
                    self?.perform("Making GIF…") { videos.compactMap(Actions.makeGIF).map { .file($0, owned: true) } }
                })
            items.append(
                ClosureMenuItem("Compress Video", symbol: "film") { [weak self] in
                    self?.perform("Compressing video…") {
                        videos.compactMap(Actions.compressVideo).map { .file($0, owned: true) }
                    }
                })
        }
        guard !items.isEmpty else { return false }
        let header = NSMenuItem(title: "Suggested", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        items.forEach(menu.addItem)
        return true
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 49:
            quickLook()
            return true  // space
        case 51, 117:
            if !shelf.selection.isEmpty { removeSelected() }
            return true  // delete
        case 53:
            shelf.selection = []
            return true  // escape
        case 36:  // return
            let selected = shelf.selectedItems
            if shelf.expanded, selected.count == 1, selected[0].kind == .file {
                rename(selected[0])
            } else {
                selected.forEach(open)
            }
            return true
        case 125 where cmd:
            shelf.selectedItems.forEach(open)
            return true  // ⌘↓
        default: break
        }
        guard cmd, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "a":
            shelf.selection = Set(shelf.items.map(\.id))
            return true
        case "k":
            showCommandBar()
            return true
        case "o":
            shelf.selectedItems.forEach(open)
            return true
        case "c":
            PB.copy(shelf.selectedOrAll)
            return true
        case "w":
            closeShelf()
            return true
        case "v":
            PB.read(.general) { [weak self] in self?.shelf.add($0) }
            return true
        default: return false
        }
    }

    // MARK: Quick Look

    func quickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if ql.isVisible {
            ql.orderOut(nil)
            return
        }
        previewURLs = shelf.selectedOrAll.compactMap(Actions.materialize)
        guard !previewURLs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        ql.makeKeyAndOrderFront(nil)
        ql.reloadData()
    }

    private func refreshPreview() {
        previewURLs = shelf.selectedOrAll.compactMap(Actions.materialize)
        QLPreviewPanel.shared().reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}
