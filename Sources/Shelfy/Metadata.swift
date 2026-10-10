import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Short secondary line for the detail list: size, pixel dimensions, item counts.
enum Metadata {
    private static var cache: [String: String] = [:]
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func summary(for item: ShelfItem) -> String {
        switch item.kind {
        case .link: return item.linkURL?.host ?? "Link"
        case .text: return "\((item.text ?? "").count) characters"
        case .file: break
        }
        guard let url = item.fileURL else { return "" }
        guard item.exists else { return "Missing" }
        if let cached = cache[url.path] { return cached }

        var parts: [String] = []
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey])
        if values?.isDirectory == true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            parts.append("Folder · \(count) item\(count == 1 ? "" : "s")")
        } else {
            if let size = values?.fileSize { parts.append(sizeFormatter.string(fromByteCount: Int64(size))) }
            if item.isImage, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
            {
                parts.append("\(w) × \(h)")
            } else if item.contentType?.conforms(to: .audiovisualContent) == true,
                let md = MDItemCreateWithURL(nil, url as CFURL),
                let seconds = MDItemCopyAttribute(md, kMDItemDurationSeconds) as? Double
            {
                let total = Int(seconds.rounded())
                parts.append(
                    total >= 3600
                        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                        : String(format: "%d:%02d", total / 60, total % 60))
            } else if let type = values?.localizedTypeDescription {
                parts.append(type)
            }
        }
        let result = parts.joined(separator: " · ")
        cache[url.path] = result
        return result
    }

    /// "3 Images", "2 PDFs", "Report.pdf", "5 Items"…
    static func title(for items: [ShelfItem]) -> String {
        if items.count == 1 { return items[0].displayName }
        let kinds = Set(items.map(kindName))
        let noun = kinds.count == 1 ? kinds.first! : "Items"
        return "\(items.count) \(noun)"
    }

    private static func kindName(_ item: ShelfItem) -> String {
        switch item.kind {
        case .link: return "Links"
        case .text: return "Texts"
        case .file:
            guard let t = item.contentType else { return "Files" }
            if t.conforms(to: .image) { return "Images" }
            if t.conforms(to: .pdf) { return "PDFs" }
            if t.conforms(to: .movie) { return "Videos" }
            if t.conforms(to: .audio) { return "Audio Files" }
            if t.conforms(to: .folder) { return "Folders" }
            return "Files"
        }
    }
}
