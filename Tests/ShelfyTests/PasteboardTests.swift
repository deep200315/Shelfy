import AppKit
import Testing

@testable import Shelfy

@Suite("Reading drops and copies")
struct PasteboardTests {
    init() { Fixtures.setUp() }

    /// A private pasteboard so tests never touch the user's clipboard.
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ShelfyTests-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func read(_ pb: NSPasteboard) async -> [ShelfItem] {
        await withCheckedContinuation { cont in PB.read(pb) { cont.resume(returning: $0) } }
    }

    @Test func fileURLsBecomeFileItems() async {
        let pb = pasteboard()
        let url = Fixtures.png(width: 4, height: 4)
        pb.writeObjects([url as NSURL])
        let items = await read(pb)
        #expect(items.map(\.kind) == [.file])
        #expect(items.first?.path == url.path)
        #expect(items.first?.owned == false)
    }

    @Test func webAddressesBecomeLinks() async {
        let pb = pasteboard()
        pb.setString("https://example.com/page", forType: .string)
        let items = await read(pb)
        #expect(items.map(\.kind) == [.link])
    }

    @Test func plainTextStaysText() async {
        let pb = pasteboard()
        pb.setString("buy milk", forType: .string)
        let items = await read(pb)
        #expect(items.first?.kind == .text)
        #expect(items.first?.text == "buy milk")
    }

    @Test func rawImageDataIsSavedAsAnOwnedPNG() async throws {
        let pb = pasteboard()
        let rep = NSBitmapImageRep(cgImage: Fixtures.cgImage(width: 8, height: 8))
        pb.setData(rep.representation(using: .png, properties: [:]), forType: .png)
        let item = try #require(await read(pb).first)
        #expect(item.kind == .file)
        #expect(item.owned)
        #expect(item.fileURL?.pathExtension == "png")
        #expect(item.exists)
    }
}

@Suite("Command Bar")
struct CommandBarTests {
    @Test func flattensSubmenusAndSkipsDisabledItems() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy") {})
        menu.addItem(ClosureMenuItem("Hidden", enabled: false) {})
        menu.addItem(.separator())
        menu.submenu("Convert Images") { $0.addItem(ClosureMenuItem("To PNG") {}) }
        menu.addItem(ClosureMenuItem(CommandBarController.menuTitle) {})

        let entries = CommandEntry.entries(from: menu)
        #expect(entries.map(\.title) == ["Copy", "To PNG"])
        #expect(entries.last?.path == "Convert Images")
    }

    @Test func runningAnEntryFiresTheMenuItem() {
        var fired = false
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Go") { fired = true })
        _ = NSApplication.shared
        CommandEntry.entries(from: menu).first?.run()
        #expect(fired)
    }
}
