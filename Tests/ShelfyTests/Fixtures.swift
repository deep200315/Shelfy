import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@testable import Shelfy

/// Shared test setup: points Shelfy's storage at a scratch folder and builds sample files.
enum Fixtures {
    /// Must run before anything touches `ShelfStore.supportDir`; every test calls it first.
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfyTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("SHELFY_SUPPORT_DIR", dir.appendingPathComponent("Support").path, 1)
        return dir
    }()

    static func setUp() { _ = root }

    static func dir(_ name: String = UUID().uuidString) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cgImage(width: Int, height: Int, color: NSColor = .systemTeal) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func png(width: Int, height: Int, name: String = "image.png", in folder: URL? = nil) -> URL {
        let url = (folder ?? dir()).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    /// A PDF with the given number of blank pages.
    static func pdf(pages: Int, name: String = "doc.pdf") -> URL {
        let doc = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(cgImage: cgImage(width: 200, height: 280), size: NSSize(width: 200, height: 280))
            doc.insert(PDFPage(image: image)!, at: i)
        }
        let url = dir().appendingPathComponent(name)
        doc.write(to: url)
        return url
    }

    static func text(_ contents: String, name: String = "note.txt") -> URL {
        let url = dir().appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A short H.264 movie made of solid frames.
    static func movie(seconds: Int = 2, fps: Int = 10, size: Int = 160) throws -> URL {
        let url = dir().appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 10 % 255), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }

    static func pixelSize(_ url: URL?) -> (width: Int, height: Int)? {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
