import AppKit
import UniformTypeIdentifiers

enum PB {
    static let readTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Reads whatever was dragged or copied into shelf items. Completion runs once, on the main queue.
    static func read(_ pb: NSPasteboard, completion: @escaping ([ShelfItem]) -> Void) {
        // 1. Real files and folders.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            completion(urls.map { .file($0) })
            return
        }

        // 2. File promises (Photos, Mail attachments, browser images…).
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dir = ShelfStore.newItemDir()
            let group = DispatchGroup()
            let lock = NSLock()
            var received: [URL] = []
            for receiver in receivers {
                let expected = max(1, receiver.fileTypes.count)
                var count = 0
                for _ in 0..<expected { group.enter() }
                receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
                    lock.lock(); defer { lock.unlock() }
                    if error == nil { received.append(url) }
                    count += 1
                    if count <= expected { group.leave() }
                }
            }
            group.notify(queue: .main) { completion(received.map { .file($0, owned: true) }) }
            return
        }

        // 3. Raw image data.
        if let png = imageData(from: pb) {
            let dir = ShelfStore.newItemDir()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = dir.appendingPathComponent("Image \(f.string(from: Date())).png")
            if (try? png.write(to: url)) != nil {
                completion([.file(url, owned: true)])
                return
            }
        }

        // 4. Web links.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let links = urls.filter { !$0.isFileURL }
            if !links.isEmpty { completion(links.map { .link($0) }); return }
        }

        // 5. Text.
        if let s = pb.string(forType: .string), !s.isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
               !trimmed.contains(" ") {
                completion([.link(url)])
            } else {
                completion([.text(s)])
            }
            return
        }
        completion([])
    }

    private static func imageData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// What goes on the pasteboard when an item is dragged out or copied.
    static func writer(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .file: return item.fileURL as NSURL?
        case .link: return item.linkURL as NSURL?
        case .text: return item.text as NSString?
        }
    }

    static func copy(_ items: [ShelfItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.compactMap(writer(for:)))
        ClipboardWatcher.ownChangeCount = pb.changeCount
    }
}
