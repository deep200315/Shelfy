import AppKit
import QuickLookThumbnailing

final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()

    @Published private(set) var images: [String: NSImage] = [:]
    private var requested = Set<String>()

    func image(for item: ShelfItem) -> NSImage {
        guard let path = item.path else {
            let symbol = item.kind == .link ? "link" : "text.alignleft"
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
        if let image = images[path] { return image }
        if !requested.contains(path) {
            requested.insert(path)
            generate(path)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// True once a real preview (not just the file-type icon) has loaded.
    func hasPreview(for item: ShelfItem) -> Bool {
        item.path.map { images[$0] != nil } ?? false
    }

    func invalidate(_ path: String) {
        requested.remove(path)
        images[path] = nil
    }

    private func generate(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 128, height: 128),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self.images[path] = image }
        }
    }
}
