import Foundation

/// Calls back with files that newly appear in a folder.
final class FolderWatcher {
    let url: URL
    private let filter: (URL) -> Bool
    private let onNew: ([URL]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()

    init(url: URL, filter: @escaping (URL) -> Bool = { _ in true }, onNew: @escaping ([URL]) -> Void) {
        self.url = url
        self.filter = filter
        self.onNew = onNew
    }

    func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Set(list())
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            // Files are often written in stages (screenshots are renamed into place); let them settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.scan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func list() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func scan() {
        let current = Set(list())
        let added = current.subtracting(known)
        known = current
        let urls = added.sorted().map { url.appendingPathComponent($0) }.filter(filter)
        if !urls.isEmpty { onNew(urls) }
    }

    static var screenshotsFolder: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot"].contains { name.hasPrefix($0) }
    }
}
