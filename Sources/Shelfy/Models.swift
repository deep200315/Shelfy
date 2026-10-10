import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Items

enum ItemKind: String, Codable {
    case file, text, link
}

struct ShelfItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ItemKind
    var path: String? = nil
    var text: String? = nil
    /// True when the file was created by Shelfy (zip output, dropped image data…) and lives in its storage.
    var owned = false

    static func file(_ url: URL, owned: Bool = false) -> ShelfItem {
        ShelfItem(kind: .file, path: url.path, owned: owned)
    }
    static func text(_ string: String) -> ShelfItem { ShelfItem(kind: .text, text: string) }
    static func link(_ url: URL) -> ShelfItem { ShelfItem(kind: .link, text: url.absoluteString) }

    var fileURL: URL? { kind == .file ? path.map { URL(fileURLWithPath: $0) } : nil }
    var linkURL: URL? { kind == .link ? text.flatMap(URL.init(string:)) : nil }
    var dedupeKey: String { path ?? text ?? id.uuidString }

    var exists: Bool {
        guard kind == .file, let path else { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    var displayName: String {
        switch kind {
        case .file: return fileURL?.lastPathComponent ?? "File"
        case .link: return linkURL?.host ?? text ?? "Link"
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Text" : String(t.prefix(80))
        }
    }

    var contentType: UTType? {
        guard let url = fileURL else { return nil }
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }
    var isImage: Bool { contentType?.conforms(to: .image) == true }
}

// MARK: - Colors

enum ShelfColor {
    static let names = ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink"]
    static let colors: [Color] = [.secondary, .red, .orange, .yellow, .green, .blue, .purple, .pink]
    static let nsColors: [NSColor] = [.secondaryLabelColor, .systemRed, .systemOrange, .systemYellow,
                                      .systemGreen, .systemBlue, .systemPurple, .systemPink]
    static func color(_ i: Int) -> Color { colors.indices.contains(i) ? colors[i] : .secondary }
}

// MARK: - Shelf

final class Shelf: ObservableObject, Identifiable {
    struct Snapshot: Codable {
        var id: UUID
        var name: String
        var colorIndex: Int
        var pinned: Bool
        var items: [ShelfItem]
        var created: Date
        var frame: String?
    }

    let id: UUID
    let created: Date
    @Published var name: String { didSet { store?.setNeedsSave() } }
    @Published var colorIndex: Int { didSet { store?.setNeedsSave() } }
    @Published var pinned: Bool { didSet { store?.setNeedsSave() } }
    @Published var items: [ShelfItem] { didSet { store?.setNeedsSave() } }
    @Published var selection: Set<UUID> = []
    @Published var isTargeted = false
    @Published var isDocked = false
    @Published var expanded = false
    @Published var showInstantActions = false
    /// Where a drag over the detail list would land (shows an insertion line).
    @Published var dropIndex: Int?
    /// Item being renamed inline in the detail list.
    @Published var renamingID: UUID?
    /// Row frames in the detail list (SwiftUI global space), used to find the drop index.
    var rowFrames: [UUID: CGRect] = [:]
    @Published var busy: String?

    var frameString: String?
    weak var store: ShelfStore?
    weak var controller: ShelfWindowController?

    init(name: String = "") {
        id = UUID(); created = Date()
        self.name = name; colorIndex = 0; pinned = false; items = []
    }

    init(snapshot s: Snapshot) {
        id = s.id; created = s.created
        name = s.name; colorIndex = s.colorIndex; pinned = s.pinned; items = s.items
        frameString = s.frame
    }

    var snapshot: Snapshot {
        Snapshot(id: id, name: name, colorIndex: colorIndex, pinned: pinned, items: items,
                 created: created, frame: frameString)
    }

    var title: String { name.isEmpty ? "Shelf" : name }

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }
    var selectedOrAll: [ShelfItem] { selection.isEmpty ? items : selectedItems }

    @discardableResult
    func add(_ new: [ShelfItem], at index: Int? = nil) -> [ShelfItem] {
        var seen = Set(items.map(\.dedupeKey))
        let fresh = new.filter { seen.insert($0.dedupeKey).inserted }
        if !fresh.isEmpty {
            items.insert(contentsOf: fresh, at: min(index ?? items.count, items.count))
        }
        return fresh
    }

    /// Moves the given items so they sit at `index` (an index into the current list).
    func move(ids: Set<UUID>, to index: Int) {
        let moving = items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let before = items.prefix(min(index, items.count)).filter { ids.contains($0.id) }.count
        var rest = items.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: min(max(index - before, 0), rest.count))
        items = rest
    }

    /// Clipboard history: newest last, re-copied items move to the end, capped in length.
    func recordClipboard(_ new: [ShelfItem], limit: Int = 60) {
        guard !new.isEmpty else { return }
        let keys = Set(new.map(\.dedupeKey))
        var list = items.filter { !keys.contains($0.dedupeKey) }
        list.append(contentsOf: new)
        if list.count > limit {
            let dropped = Array(list.prefix(list.count - limit))
            list.removeFirst(dropped.count)
            ShelfStore.cleanupOwned(dropped)
        }
        items = list
    }

    func remove(ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        ShelfStore.cleanupOwned(removed)
    }
}

// MARK: - Store

enum Placement {
    case centered(NSPoint)
    case below(NSPoint)
    case corner
    case restore
}

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var openShelves: [Shelf] = []
    @Published private(set) var recentShelves: [Shelf] = []
    @Published var dragActive = false
    /// Always-available shelf that collects clipboard history; never moves to Recent.
    private(set) var clipboardShelf: Shelf = {
        let s = Shelf(name: "Clipboard")
        s.pinned = true
        return s
    }()
    private var controllers: [UUID: ShelfWindowController] = [:]
    private var saveWork: DispatchWorkItem?
    private let maxRecent = 20

    static let supportDir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shelfy", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var itemsDir: URL { supportDir.appendingPathComponent("Items", isDirectory: true) }
    private static var stateURL: URL { supportDir.appendingPathComponent("shelves.json") }

    /// A fresh directory for files Shelfy creates.
    static func newItemDir() -> URL {
        let url = itemsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanupOwned(_ items: [ShelfItem]) {
        let root = itemsDir.standardizedFileURL.path
        for item in items where item.owned {
            guard let dir = item.fileURL?.deletingLastPathComponent().standardizedFileURL,
                  dir.path.hasPrefix(root), dir.path != root else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Shelf lifecycle

    @discardableResult
    func newShelf(items: [ShelfItem] = [], name: String = "", placement: Placement) -> Shelf {
        let shelf = Shelf(name: name)
        shelf.store = self
        shelf.add(items)
        open(shelf, placement: placement)
        return shelf
    }

    func isClipboard(_ shelf: Shelf) -> Bool { shelf === clipboardShelf }

    func toggleClipboard(placement: Placement) {
        if openShelves.contains(where: { $0 === clipboardShelf }) {
            close(clipboardShelf)
        } else {
            open(clipboardShelf, placement: placement)
        }
    }

    func open(_ shelf: Shelf, placement: Placement) {
        shelf.store = self
        recentShelves.removeAll { $0.id == shelf.id }
        if !openShelves.contains(where: { $0.id == shelf.id }) { openShelves.append(shelf) }
        let controller = controllers[shelf.id] ?? ShelfWindowController(shelf: shelf)
        controllers[shelf.id] = controller
        controller.present(placement)
        setNeedsSave()
    }

    func close(_ shelf: Shelf) {
        controllers[shelf.id]?.close()
        controllers[shelf.id] = nil
        openShelves.removeAll { $0.id == shelf.id }
        if isClipboard(shelf) {
            setNeedsSave()
            return
        }
        if shelf.items.isEmpty {
            recentShelves.removeAll { $0.id == shelf.id }
        } else {
            recentShelves.removeAll { $0.id == shelf.id }
            recentShelves.insert(shelf, at: 0)
            while recentShelves.count > maxRecent {
                let dropped = recentShelves.removeLast()
                Self.cleanupOwned(dropped.items)
            }
        }
        setNeedsSave()
    }

    func controller(for shelf: Shelf) -> ShelfWindowController? { controllers[shelf.id] }

    func shelf(named name: String) -> Shelf? { openShelves.first { $0.name == name } }

    /// An open shelf with nothing on it, which can be reused instead of creating another.
    var emptyOpenShelf: Shelf? { openShelves.last { $0.items.isEmpty && !$0.pinned } }

    func clearRecent() {
        recentShelves.forEach { Self.cleanupOwned($0.items) }
        recentShelves.removeAll()
        setNeedsSave()
    }

    func removeFromRecent(_ shelf: Shelf) {
        recentShelves.removeAll { $0.id == shelf.id }
        Self.cleanupOwned(shelf.items)
        setNeedsSave()
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var open: [Shelf.Snapshot]
        var recent: [Shelf.Snapshot]
        var clipboard: Shelf.Snapshot?
    }

    func setNeedsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        let state = Persisted(open: openShelves.filter { !isClipboard($0) }.map(\.snapshot),
                              recent: recentShelves.map(\.snapshot),
                              clipboard: clipboardShelf.snapshot)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    func load() {
        clipboardShelf.store = self
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        if let snap = state.clipboard {
            clipboardShelf = Shelf(snapshot: snap)
            clipboardShelf.pinned = true
        }
        clipboardShelf.store = self
        recentShelves = state.recent.map { let s = Shelf(snapshot: $0); s.store = self; return s }
        for snap in state.open {
            let shelf = Shelf(snapshot: snap)
            if shelf.items.isEmpty && !shelf.pinned { continue }
            open(shelf, placement: .restore)
        }
    }
}
