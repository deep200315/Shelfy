import AppKit
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import Shelfy

@Suite("Built-in actions")
struct ActionsTests {
    init() { Fixtures.setUp() }

    @Test func zipOfOneFileIsNamedAfterIt() throws {
        let src = Fixtures.text("hello", name: "notes.txt")
        let zip = try #require(Actions.zip([src]))
        #expect(zip.lastPathComponent == "notes.zip")
        #expect(Fixtures.fileSize(zip) > 0)
    }

    @Test func zipOfSeveralFilesContainsThemAll() throws {
        let a = Fixtures.text("a", name: "a.txt")
        let b = Fixtures.text("b", name: "b.txt")
        let zip = try #require(Actions.zip([a, b]))
        let listing = Actions.run("/usr/bin/zipinfo", ["-1", zip.path]).output
        #expect(listing.contains("a.txt"))
        #expect(listing.contains("b.txt"))
    }

    @Test func convertChangesTheFileType() throws {
        let src = Fixtures.png(width: 20, height: 10)
        let out = try #require(Actions.convert([src], to: .jpeg).first)
        #expect(out.pathExtension == "jpeg")
        #expect(Fixtures.pixelSize(out)?.width == 20)
    }

    @Test func resizeRespectsTheMaximumEdge() throws {
        let src = Fixtures.png(width: 400, height: 200)
        let out = try #require(Actions.resize([src], maxPixel: 100).first)
        #expect(Fixtures.pixelSize(out)?.width == 100)
        #expect(Fixtures.pixelSize(out)?.height == 50)
    }

    @Test func resizeByScaleHalvesTheImage() throws {
        let src = Fixtures.png(width: 400, height: 200)
        let out = try #require(Actions.resize([src], scale: 0.5).first)
        #expect(Fixtures.pixelSize(out)?.width == 200)
    }

    @Test func extractTextReadsTextItemsAndFiles() {
        let file = Fixtures.text("from a file")
        let text = Actions.extractText([.text("typed"), .file(file)])
        #expect(text.contains("typed"))
        #expect(text.contains("from a file"))
    }

    @Test func uniqueURLNeverOverwrites() {
        let folder = Fixtures.dir()
        _ = Fixtures.png(width: 2, height: 2, name: "x.png", in: folder)
        #expect(Actions.uniqueURL(in: folder, name: "x.png").lastPathComponent == "x 2.png")
    }
}

@Suite("Suggested actions")
struct SmartActionsTests {
    init() { Fixtures.setUp() }

    @Test func stitchVerticallyScalesToTheNarrowestWidth() throws {
        let a = Fixtures.png(width: 200, height: 100, name: "a.png")
        let b = Fixtures.png(width: 100, height: 100, name: "b.png")
        let size = try #require(Fixtures.pixelSize(Actions.stitch([a, b], vertical: true)))
        #expect(size.width == 100)
        #expect(size.height == 150)  // 200×100 → 100×50, plus 100×100
    }

    @Test func stitchSideBySideScalesToTheShortestHeight() throws {
        let a = Fixtures.png(width: 100, height: 200, name: "a.png")
        let b = Fixtures.png(width: 100, height: 100, name: "b.png")
        let size = try #require(Fixtures.pixelSize(Actions.stitch([a, b], vertical: false)))
        #expect(size.height == 100)
        #expect(size.width == 150)
    }

    @Test func stitchNeedsAtLeastTwoImages() {
        #expect(Actions.stitch([Fixtures.png(width: 10, height: 10)], vertical: true) == nil)
    }

    @Test func imagesBecomeOnePDFPageEach() throws {
        let images = (1...3).map { Fixtures.png(width: 30, height: 40, name: "i\($0).png") }
        let pdf = try #require(Actions.imagesToPDF(images))
        #expect(PDFDocument(url: pdf)?.pageCount == 3)
    }

    @Test func mergePDFsKeepsEveryPage() throws {
        let merged = try #require(Actions.mergePDFs([Fixtures.pdf(pages: 2), Fixtures.pdf(pages: 3)]))
        #expect(PDFDocument(url: merged)?.pageCount == 5)
    }

    @Test func gifHasOneFramePerTenthOfASecond() throws {
        let movie = try Fixtures.movie(seconds: 2, fps: 10)
        let gif = try #require(Actions.makeGIF(movie))
        let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 20)
    }

    /// Regression: compressing a small video once produced a file 3× larger than the original.
    @Test func compressVideoNeverReturnsALargerFile() throws {
        let movie = try Fixtures.movie(seconds: 2, fps: 10)
        if let out = Actions.compressVideo(movie) {
            #expect(Fixtures.fileSize(out) < Fixtures.fileSize(movie))
        }
    }
}
