import Foundation
import Testing

@testable import Shelfy

@Suite("Shelf model")
struct ShelfModelTests {
    init() { Fixtures.setUp() }

    private func shelf(_ texts: [String]) -> Shelf {
        let shelf = Shelf()
        shelf.items = texts.map { ShelfItem.text($0) }
        return shelf
    }

    private func texts(_ shelf: Shelf) -> String { shelf.items.compactMap(\.text).joined() }

    @Test func addSkipsItemsAlreadyOnTheShelf() {
        let shelf = shelf(["a", "b"])
        let added = shelf.add([.text("b"), .text("c"), .text("c")])
        #expect(added.map(\.text) == ["c"])
        #expect(texts(shelf) == "abc")
    }

    @Test func addInsertsAtTheDropIndex() {
        let shelf = shelf(["a", "b"])
        shelf.add([.text("x")], at: 1)
        #expect(texts(shelf) == "axb")
    }

    @Test func addClampsAnOutOfRangeIndexToTheEnd() {
        let shelf = shelf(["a"])
        shelf.add([.text("x")], at: 99)
        #expect(texts(shelf) == "ax")
    }

    @Test func moveReordersOneItemDownward() {
        let shelf = shelf(["a", "b", "c", "d", "e"])
        shelf.move(ids: [shelf.items[0].id], to: 3)
        #expect(texts(shelf) == "bcade")
    }

    @Test func moveKeepsAGroupTogetherAndInOrder() {
        let shelf = shelf(["a", "b", "c", "d", "e"])
        shelf.move(ids: [shelf.items[3].id, shelf.items[4].id], to: 0)
        #expect(texts(shelf) == "deabc")
    }

    @Test func moveToTheEnd() {
        let shelf = shelf(["a", "b", "c"])
        shelf.move(ids: [shelf.items[0].id], to: 3)
        #expect(texts(shelf) == "bca")
    }

    @Test func clipboardRecopyMovesItemToTheEnd() {
        let shelf = Shelf()
        shelf.recordClipboard([.text("x")])
        shelf.recordClipboard([.text("y")])
        shelf.recordClipboard([.text("x")])
        #expect(texts(shelf) == "yx")
    }

    @Test func clipboardKeepsOnlyTheNewestItems() {
        let shelf = Shelf()
        for i in 0..<70 { shelf.recordClipboard([.text("n\(i)")], limit: 60) }
        #expect(shelf.items.count == 60)
        #expect(shelf.items.first?.text == "n10")
        #expect(shelf.items.last?.text == "n69")
    }

    @Test func selectedOrAllFallsBackToEverything() {
        let shelf = shelf(["a", "b"])
        #expect(shelf.selectedOrAll.count == 2)
        shelf.selection = [shelf.items[1].id]
        #expect(shelf.selectedOrAll.map(\.text) == ["b"])
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let shelf = shelf(["a"])
        shelf.name = "Work"
        shelf.colorIndex = 3
        shelf.pinned = true
        let data = try JSONEncoder().encode(shelf.snapshot)
        let restored = Shelf(snapshot: try JSONDecoder().decode(Shelf.Snapshot.self, from: data))
        #expect(restored.id == shelf.id)
        #expect(restored.name == "Work")
        #expect(restored.colorIndex == 3)
        #expect(restored.pinned)
        #expect(restored.items == shelf.items)
    }

    @Test func linkItemsShowTheirHost() {
        #expect(ShelfItem.link(URL(string: "https://developer.apple.com/x")!).displayName == "developer.apple.com")
    }
}

@Suite("Metadata")
struct MetadataTests {
    init() { Fixtures.setUp() }

    @Test func titleUsesTheFileNameForOneItem() {
        #expect(Metadata.title(for: [.file(URL(fileURLWithPath: "/tmp/Report.pdf"))]) == "Report.pdf")
    }

    @Test func titleNamesTheKindWhenAllItemsMatch() {
        let images = (1...3).map { Fixtures.png(width: 4, height: 4, name: "p\($0).png") }
        #expect(Metadata.title(for: images.map { .file($0) }) == "3 Images")
    }

    @Test func titleFallsBackToItemsForMixedKinds() {
        let items: [ShelfItem] = [.file(Fixtures.png(width: 4, height: 4)), .text("hi")]
        #expect(Metadata.title(for: items) == "2 Items")
    }

    @Test func summaryShowsImageDimensions() {
        let url = Fixtures.png(width: 64, height: 32)
        #expect(Metadata.summary(for: .file(url)).contains("64 × 32"))
    }

    @Test func summaryCountsFolderContents() {
        let folder = Fixtures.dir()
        _ = Fixtures.png(width: 2, height: 2, name: "a.png", in: folder)
        _ = Fixtures.png(width: 2, height: 2, name: "b.png", in: folder)
        #expect(Metadata.summary(for: .file(folder)) == "Folder · 2 items")
    }

    @Test func summaryFlagsMissingFiles() {
        #expect(Metadata.summary(for: .file(URL(fileURLWithPath: "/nonexistent/x.png"))) == "Missing")
    }
}
