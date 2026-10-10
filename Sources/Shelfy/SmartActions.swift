import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Actions suggested by what's on the shelf: stitch/PDF for images, merge for PDFs, GIF/compress for videos.
extension Actions {
    static func urls(_ items: [ShelfItem], conformingTo type: UTType) -> [URL] {
        items.filter { $0.exists && $0.contentType?.conforms(to: type) == true }.compactMap(\.fileURL)
    }

    // MARK: Images

    static func stitch(_ urls: [URL], vertical: Bool) -> URL? {
        let images: [CGImage] = urls.compactMap { url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        guard images.count >= 2 else { return nil }

        // Scale everything to the smallest shared edge so nothing is upscaled.
        let side = vertical ? images.map(\.width).min()! : images.map(\.height).min()!
        let sizes: [CGSize] = images.map { img in
            vertical
                ? CGSize(width: side, height: Int((Double(img.height) * Double(side) / Double(img.width)).rounded()))
                : CGSize(width: Int((Double(img.width) * Double(side) / Double(img.height)).rounded()), height: side)
        }
        let width = vertical ? CGFloat(side) : sizes.reduce(0) { $0 + $1.width }
        let height = vertical ? sizes.reduce(0) { $0 + $1.height } : CGFloat(side)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        var cursor: CGFloat = vertical ? height : 0
        for (img, size) in Swift.zip(images, sizes) {
            if vertical {
                cursor -= size.height
                ctx.draw(img, in: CGRect(x: 0, y: cursor, width: size.width, height: size.height))
            } else {
                ctx.draw(img, in: CGRect(x: cursor, y: 0, width: size.width, height: size.height))
                cursor += size.width
            }
        }
        guard let result = ctx.makeImage() else { return nil }
        let out = uniqueURL(in: ShelfStore.newItemDir(), name: "Stitched.png")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, result, nil)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    static func imagesToPDF(_ urls: [URL]) -> URL? {
        let doc = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { return nil }
        let out = uniqueURL(in: ShelfStore.newItemDir(), name: "Images.pdf")
        return doc.write(to: out) ? out : nil
    }

    // MARK: PDFs

    static func mergePDFs(_ urls: [URL]) -> URL? {
        let merged = PDFDocument()
        for url in urls {
            guard let doc = PDFDocument(url: url) else { continue }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { merged.insert(page, at: merged.pageCount) }
            }
        }
        guard merged.pageCount > 0 else { return nil }
        let out = uniqueURL(in: ShelfStore.newItemDir(), name: "Merged.pdf")
        return merged.write(to: out) ? out : nil
    }

    // MARK: Video

    /// First 15 seconds at 10 fps, max 480 px.
    static func makeGIF(_ url: URL) -> URL? {
        let asset = AVURLAsset(url: url)
        let duration = min(loadDuration(asset), 15)
        guard duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let fps = 10.0
        let frameCount = max(1, Int(duration * fps))
        let out = uniqueURL(in: ShelfStore.newItemDir(), name: url.deletingPathExtension().lastPathComponent + ".gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            CGImageDestinationAddImage(dest, frame, frameProps)
            added += 1
        }
        guard added > 0 else { return nil }
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    /// Re-encodes with a few presets and keeps the smallest result — only if it's actually smaller than the original.
    static func compressVideo(_ url: URL) -> URL? {
        let asset = AVURLAsset(url: url)
        let dir = ShelfStore.newItemDir()
        let name = url.deletingPathExtension().lastPathComponent + " (compressed).mp4"
        let originalSize = fileSize(url)
        var best: (url: URL, size: Int)?
        for preset in [AVAssetExportPresetHEVC1920x1080, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let out = uniqueURL(in: dir, name: name)
            session.outputURL = out
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let done = DispatchSemaphore(value: 0)
            session.exportAsynchronously { done.signal() }
            done.wait()
            let size = fileSize(out)
            if session.status == .completed, size > 0, size < (best?.size ?? originalSize) {
                if let old = best { try? FileManager.default.removeItem(at: old.url) }
                best = (out, size)
                if size < originalSize / 2 { break }   // good enough; skip the lower-quality presets
            } else {
                try? FileManager.default.removeItem(at: out)
            }
        }
        if let best {
            let final = dir.appendingPathComponent(name)
            if best.url != final { try? FileManager.default.moveItem(at: best.url, to: final) }
            return final
        }
        try? FileManager.default.removeItem(at: dir)
        return nil
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// Blocking duration load; only called from the background actions queue.
    private static func loadDuration(_ asset: AVURLAsset) -> Double {
        let result = Box(0.0)
        let done = DispatchSemaphore(value: 0)
        Task {
            if let d = try? await asset.load(.duration) { result.value = CMTimeGetSeconds(d) }
            done.signal()
        }
        done.wait()
        return result.value
    }
}
