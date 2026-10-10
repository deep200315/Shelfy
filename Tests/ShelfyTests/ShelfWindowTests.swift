import AppKit
import Testing

@testable import Shelfy

@MainActor
@Suite("Shelf window", .serialized)
struct ShelfWindowTests {
    init() {
        Fixtures.setUp()
        _ = NSApplication.shared
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Regression: a new shelf slid to the bottom-left corner because a spurious "collapse"
    /// animation ran from the window's pre-placement frame.
    @Test func newShelfStaysCenteredUnderThePointer() {
        let shelf = Shelf()
        let controller = ShelfWindowController(shelf: shelf)
        let screen = NSScreen.main!.visibleFrame
        let point = NSPoint(x: screen.midX, y: screen.midY)

        controller.present(.centered(point))
        spinRunLoop(0.6)  // longer than the resize animation

        let frame = controller.window!.frame
        #expect(abs(frame.midX - point.x) < 1)
        #expect(abs(frame.midY - point.y) < 1)
        controller.close()
    }

    @Test func expandingKeepsTheTopEdgeInPlace() {
        let shelf = Shelf()
        shelf.items = [.text("a")]
        let controller = ShelfWindowController(shelf: shelf)
        let screen = NSScreen.main!.visibleFrame
        controller.present(.centered(NSPoint(x: screen.midX, y: screen.midY)))
        let top = controller.window!.frame.maxY

        shelf.expanded = true
        spinRunLoop(0.6)

        #expect(controller.window!.frame.size == ShelfWindowController.expandedSize)
        #expect(abs(controller.window!.frame.maxY - top) < 1)
        controller.close()
    }

    @Test func collapsingClearsTheSelection() {
        let shelf = Shelf()
        shelf.items = [.text("a"), .text("b")]
        let controller = ShelfWindowController(shelf: shelf)
        controller.present(.centered(NSPoint(x: 600, y: 500)))
        shelf.expanded = true
        spinRunLoop(0.4)
        shelf.selection = [shelf.items[0].id]

        shelf.expanded = false
        spinRunLoop(0.4)

        #expect(shelf.selection.isEmpty)
        #expect(shelf.selectedOrAll.count == 2)
        controller.close()
    }
}
