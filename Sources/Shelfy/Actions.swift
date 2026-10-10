import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum Actions {
    static let queue = DispatchQueue(label: "shelfy.actions", qos: .userInitiated)

    // MARK: Helpers

    static func fileURLs(_ items: [ShelfItem]) -> [URL] {
        items.compactMap(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func imageURLs(_ items: [ShelfItem]) -> [URL] {
        items.filter(\.isImage).compactMap(\.fileURL)
    }

    static func textSourceCount(_ items: [ShelfItem]) -> Int {
        items.filter { item in
            if item.kind != .file { return item.kind == .text }
            guard let t = item.contentType else { return false }
            return t.conforms(to: .image) || t.conforms(to: .pdf) || t.conforms(to: .text)
        }.count
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Writes text items to temporary files so they can be previewed or zipped.
    static func materialize(_ item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: return item.fileURL
        case .text:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shelfy-\(item.id.uuidString.prefix(8)).txt")
            try? (item.text ?? "").write(to: url, atomically: true, encoding: .utf8)
            return url
        case .link: return nil
        }
    }

    // MARK: Archive

    static func zip(_ urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let dir = ShelfStore.newItemDir()
        if urls.count == 1 {
            let src = urls[0]
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let base = isDir ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
            let out = dir.appendingPathComponent(base + ".zip")
            run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, out.path])
            return FileManager.default.fileExists(atPath: out.path) ? out : nil
        }
        let staging = dir.appendingPathComponent("Archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for url in urls {
            try? FileManager.default.copyItem(at: url, to: uniqueURL(in: staging, name: url.lastPathComponent))
        }
        let out = dir.appendingPathComponent("Archive.zip")
        run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, out.path])
        try? FileManager.default.removeItem(at: staging)
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }

    // MARK: Images

    static func convert(_ urls: [URL], to type: UTType) -> [URL] {
        let dir = ShelfStore.newItemDir()
        return urls.compactMap { src in
            guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let ext = type.preferredFilenameExtension ?? "img"
            let out = uniqueURL(in: dir, name: src.deletingPathExtension().lastPathComponent + "." + ext)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)
            else { return nil }
            var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out : nil
        }
    }

    /// Resizes to a max pixel dimension, or by a scale factor of the original.
    static func resize(_ urls: [URL], maxPixel: Int? = nil, scale: Double? = nil) -> [URL] {
        let dir = ShelfStore.newItemDir()
        return urls.compactMap { src in
            guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let target = maxPixel ?? Int(Double(max(w, h)) * (scale ?? 1))
            guard target > 0 else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
            let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
            let name = "\(src.deletingPathExtension().lastPathComponent) (\(thumb.width)×\(thumb.height)).\(src.pathExtension)"
            let out = uniqueURL(in: dir, name: name)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out : nil
        }
    }

    // MARK: Text recognition

    static func extractText(_ items: [ShelfItem]) -> String {
        var parts: [String] = []
        for item in items {
            if item.kind == .text, let t = item.text { parts.append(t); continue }
            guard let url = item.fileURL, let type = item.contentType else { continue }
            if type.conforms(to: .pdf), let doc = PDFDocument(url: url) {
                let s = doc.string ?? ""
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(s); continue }
                for i in 0..<min(doc.pageCount, 50) {
                    guard let page = doc.page(at: i) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let image = page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { parts.append(ocr(cg)) }
                }
            } else if type.conforms(to: .image),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                parts.append(ocr(cg))
            } else if type.conforms(to: .text), let s = try? String(contentsOf: url, encoding: .utf8) {
                parts.append(s)
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Sharing

    static func shareables(_ items: [ShelfItem]) -> [Any] {
        items.compactMap { item -> Any? in
            switch item.kind {
            case .file: return item.fileURL
            case .link: return item.linkURL
            case .text: return item.text
            }
        }
    }

    static func perform(_ service: NSSharingService.Name, _ items: [ShelfItem]) {
        NSApp.activate(ignoringOtherApps: true)
        NSSharingService(named: service)?.perform(withItems: shareables(items))
    }

    static func saveCopies(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save copies of \(urls.count) item\(urls.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        for url in urls {
            try? FileManager.default.copyItem(at: url, to: uniqueURL(in: dest, name: url.lastPathComponent))
        }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    // MARK: Shortcuts

    private(set) static var shortcutNames: [String] = []

    static func refreshShortcuts() {
        queue.async {
            let out = run("/usr/bin/shortcuts", ["list"])
            let names = out.status == 0
                ? out.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
                : []
            DispatchQueue.main.async { shortcutNames = names }
        }
    }

    static func runShortcut(_ name: String, _ urls: [URL]) -> String {
        var args = ["run", name]
        if !urls.isEmpty { args += ["-i"] + urls.map(\.path) }
        return run("/usr/bin/shortcuts", args).output
    }

    // MARK: Custom scripts

    static var scriptsDir: URL {
        let dir = ShelfStore.supportDir.appendingPathComponent("Scripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let example = dir.appendingPathComponent("Word Count.sh")
            let body = """
            #!/bin/sh
            # Shelfy custom action: receives the selected files as arguments.
            # Output lines that are existing file paths are added to the shelf; anything else becomes a text item.
            wc -w "$@"
            """
            try? body.write(to: example, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: example.path)
        }
        return dir
    }

    static func scripts() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { FileManager.default.isExecutableFile(atPath: $0.path) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func runScript(_ script: URL, _ urls: [URL]) -> [ShelfItem] {
        let output = run(script.path, urls.map(\.path)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return [] }
        let lines = output.split(separator: "\n").map(String.init)
        if lines.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
            return lines.map { .file(URL(fileURLWithPath: $0)) }
        }
        return [.text(output)]
    }
}
