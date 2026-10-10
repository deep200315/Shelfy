import AppKit
import Carbon
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private var statusItem: NSStatusItem!
    private let store = ShelfStore.shared
    private let settings = Settings.shared
    private let dragMonitor = DragMonitor()
    private let notch = NotchDropZone()
    private var hotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private let clipboardWatcher = ClipboardWatcher()
    private var watchers: [FolderWatcher] = []
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        store.load()

        dragMonitor.onShake = { [weak self] point in self?.openShelf(at: point) }
        dragMonitor.onDragChanged = { [weak self] active in self?.dragChanged(active) }
        dragMonitor.start()

        notch.onDrop = { [weak self] items, point in
            self?.store.newShelf(items: items, placement: .below(point))
        }

        hotKey = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.openShelf(at: NSEvent.mouseLocation)
        }
        clipboardHotKey = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.store.toggleClipboard(placement: .centered(NSEvent.mouseLocation))
        }
        clipboardWatcher.start()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let panel = NSApp.keyWindow as? ShelfPanel, let controller = panel.controller,
                !(panel.firstResponder is NSText)
            else { return event }
            return controller.handleKey(event) ? nil : event
        }

        settings.$collectScreenshots.combineLatest(settings.$watchedFolders)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.reconfigureWatchers() }
            .store(in: &cancellables)

        Actions.refreshShortcuts()

        // Debug: SHELFY_SNAPSHOT=/path/prefix renders each open shelf's view to PNG (glass itself does not render offscreen).
        if let prefix = ProcessInfo.processInfo.environment["SHELFY_SNAPSHOT"] {
            if ProcessInfo.processInfo.environment["SHELFY_EXPAND"] != nil { store.openShelves.first?.expanded = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                for (i, shelf) in (self?.store.openShelves ?? []).enumerated() {
                    guard let view = self?.store.controller(for: shelf)?.window?.contentView,
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)\(i).png"))
                }
            }
        }

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showSettings()
        }
    }

    // MARK: Opening shelves

    private func openShelf(at point: NSPoint) {
        if let empty = store.emptyOpenShelf, let controller = store.controller(for: empty) {
            controller.moveTo(center: point)
        } else {
            store.newShelf(placement: .centered(point))
        }
    }

    private func dragChanged(_ active: Bool) {
        store.dragActive = active
        if active, settings.notchEnabled { notch.show() } else { notch.hide() }
    }

    // MARK: Watched folders

    private func reconfigureWatchers() {
        watchers.forEach { $0.stop() }
        watchers = []
        if settings.collectScreenshots {
            let w = FolderWatcher(url: FolderWatcher.screenshotsFolder, filter: FolderWatcher.isScreenshot) { [weak self] urls in
                self?.collect(urls, into: "Screenshots")
            }
            w.start()
            watchers.append(w)
        }
        for path in settings.watchedFolders {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let w = FolderWatcher(url: url) { [weak self] urls in self?.collect(urls, into: url.lastPathComponent) }
            w.start()
            watchers.append(w)
        }
    }

    private func collect(_ urls: [URL], into name: String) {
        let items = urls.map { ShelfItem.file($0) }
        if let shelf = store.shelf(named: name) {
            shelf.add(items)
            store.controller(for: shelf)?.bringToFront()
        } else {
            store.newShelf(items: items, name: name, placement: .corner)
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Stacked photos, matching the app icon; system symbols render as menu bar templates.
        statusItem.button?.image = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: "Shelfy")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Accept drops onto the menu bar icon.
        if let window = statusItem.button?.window {
            window.registerForDraggedTypes(PB.readTypes)
            window.delegate = self
        }
    }

    private var statusItemAnchor: NSPoint {
        guard let button = statusItem.button, let window = button.window else { return NSEvent.mouseLocation }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSPoint(x: frame.midX, y: frame.minY)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        statusItem.button?.highlight(true)
        Feedback.enter()
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        Feedback.drop()
        let anchor = statusItemAnchor
        PB.read(sender.draggingPasteboard) { [weak self] items in
            guard !items.isEmpty else { return }
            self?.store.newShelf(items: items, placement: .below(anchor))
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let newItem = ClosureMenuItem("New Shelf", key: "d", symbol: "plus.rectangle.on.rectangle") { [weak self] in
            guard let self else { return }
            self.store.newShelf(placement: .below(self.statusItemAnchor))
        }
        newItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(newItem)
        menu.addItem(
            ClosureMenuItem("New Shelf from Clipboard", symbol: "doc.on.clipboard") { [weak self] in
                guard let self else { return }
                let anchor = self.statusItemAnchor
                PB.read(.general) { items in self.store.newShelf(items: items, placement: .below(anchor)) }
            })

        let clipboard = ClosureMenuItem("Clipboard History", key: "v", symbol: "list.clipboard") { [weak self] in
            guard let self else { return }
            self.store.toggleClipboard(placement: .below(self.statusItemAnchor))
        }
        clipboard.keyEquivalentModifierMask = [.control, .option]
        clipboard.state = store.openShelves.contains { store.isClipboard($0) } ? .on : .off
        menu.addItem(clipboard)

        if !store.openShelves.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Open Shelves", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for shelf in store.openShelves {
                menu.addItem(shelfMenuItem(shelf) { [weak self] in self?.store.controller(for: shelf)?.bringToFront() })
            }
            menu.addItem(
                ClosureMenuItem("Close All Shelves", symbol: "xmark.rectangle") { [weak self] in
                    self?.store.openShelves.forEach { self?.store.close($0) }
                })
        }

        menu.addItem(.separator())
        menu.submenu("Recent Shelves", symbol: "clock.arrow.circlepath") { sub in
            if store.recentShelves.isEmpty {
                let none = NSMenuItem(title: "No Recent Shelves", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            } else {
                for shelf in store.recentShelves {
                    sub.addItem(
                        shelfMenuItem(shelf) { [weak self] in
                            guard let self else { return }
                            self.store.open(shelf, placement: .below(self.statusItemAnchor))
                        })
                }
                sub.addItem(.separator())
                sub.addItem(ClosureMenuItem("Clear Recent Shelves") { [weak self] in self?.store.clearRecent() })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", key: ",", symbol: "gearshape") { [weak self] in self?.showSettings() })
        menu.addItem(ClosureMenuItem("Quit Shelfy", key: "q") { NSApp.terminate(nil) })
    }

    private func shelfMenuItem(_ shelf: Shelf, action: @escaping () -> Void) -> NSMenuItem {
        let count = shelf.items.count
        let item = ClosureMenuItem("\(shelf.title) — \(count) item\(count == 1 ? "" : "s")", handler: action)
        let symbol = shelf.pinned ? "pin.circle.fill" : "circle.fill"
        let color = shelf.colorIndex == 0 ? NSColor.tertiaryLabelColor : ShelfColor.nsColors[shelf.colorIndex]
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        return item
    }

    // MARK: Settings

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Shelfy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }
}
