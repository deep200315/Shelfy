import AppKit
import SwiftUI

/// A searchable list of every action in a shelf's menu (⌘K).
struct CommandEntry: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let image: NSImage?
    let item: NSMenuItem

    var searchText: String { (path + " " + title).lowercased() }

    func run() {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    static func entries(from menu: NSMenu, path: String = "") -> [CommandEntry] {
        menu.items.flatMap { item -> [CommandEntry] in
            if item.isSeparatorItem || item.isHidden { return [] }
            if let sub = item.submenu {
                return entries(from: sub, path: path.isEmpty ? item.title : "\(path) › \(item.title)")
            }
            guard item.isEnabled, item.action != nil, item.title != CommandBarController.menuTitle else { return [] }
            return [CommandEntry(title: item.title, path: path, image: item.image, item: item)]
        }
    }
}

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CommandBarController: NSObject, NSWindowDelegate {
    static let menuTitle = "Command Bar…"
    private static var current: CommandBarController?
    private let panel: CommandBarPanel

    /// Opens over the given shelf window with that shelf's actions.
    static func show(entries: [CommandEntry], over window: NSWindow) {
        current?.close()
        let controller = CommandBarController(entries: entries)
        current = controller
        let size = controller.panel.frame.size
        let f = window.frame
        var origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
        if let vf = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        controller.panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        controller.panel.makeKeyAndOrderFront(nil)
    }

    private init(entries: [CommandEntry]) {
        panel = CommandBarPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: 300 + 2 * ShelfContainerView.margin, height: 318 + 2 * ShelfContainerView.margin),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        if #available(macOS 26, *) { panel.hasShadow = false } else { panel.hasShadow = true }
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let view = CommandBarView(
            entries: entries,
            onRun: { [weak self] entry in
                self?.close()
                DispatchQueue.main.async { entry.run() }
            },
            onCancel: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let m = ShelfContainerView.margin
        let inner = NSRect(origin: .zero, size: panel.frame.size).insetBy(dx: m, dy: m)
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: inner)
            glass.cornerRadius = ShelfContainerView.cornerRadius
            hosting.frame = glass.bounds
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            container.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: inner)
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = ShelfContainerView.cornerRadius
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            container.addSubview(effect)
        }
        panel.contentView = container
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func close() {
        panel.delegate = nil
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}

private struct CommandBarView: View {
    let entries: [CommandEntry]
    let onRun: (CommandEntry) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [CommandEntry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { e in words.allSatisfy { e.searchText.contains($0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { if let e = results[safe: selected] { onRun(e) } }
                    .onKeyPress(.downArrow) {
                        move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
            .padding(10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            row(entry, highlighted: index == selected)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onRun(entry) }
                                .onPanelHover { if $0 { selected = index } }
                        }
                        if results.isEmpty {
                            Text("No matching actions")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: selected) { _, new in
                    if let e = results[safe: new] { proxy.scrollTo(e.id) }
                }
            }
        }
        .onChange(of: query) { selected = 0 }
        .onAppear { focused = true }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    private func row(_ entry: CommandEntry, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image = entry.image {
                    Image(nsImage: image).renderingMode(.template)
                } else {
                    Image(systemName: "circle.dashed")
                }
            }
            .frame(width: 18)
            .foregroundStyle(highlighted ? Color.white : Color.secondary)
            Text(entry.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !entry.path.isEmpty {
                Text(entry.path)
                    .font(.system(size: 11))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor : .clear))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
