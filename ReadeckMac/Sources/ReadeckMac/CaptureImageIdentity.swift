import CoreGraphics
import Foundation
import ImageIO

enum CaptureImageIdentity {
    struct Value: Sendable {
        let width: Int
        let height: Int
        let fingerprint: String
        var frameCount: Int = 1
        var frameFingerprints: [String]? = nil
    }
    static func read(_ data: Data) -> Value? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int, rawHeight > 0, rawWidth > 0,
              rawWidth <= CaptureLimits().maximumImagePixels / rawHeight,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 300, rawWidth * rawHeight <= CaptureLimits().maximumImagePixels / count else { return nil }
        func fingerprint(_ image: CGImage) -> String? {
            var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                return true
            }
            guard success else { return nil }
            return Data(bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }).base64EncodedString()
        }
        guard let first = fingerprint(image) else { return nil }
        var frames = [first]
        for index in 1..<count {
            guard let next = CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary),
                let signature = fingerprint(next) else { return nil }
            frames.append(signature)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return Value(width: rotated ? rawHeight : rawWidth, height: rotated ? rawWidth : rawHeight,
            fingerprint: first, frameCount: count, frameFingerprints: count > 1 ? frames : nil)
    }

    static func resembles(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right, let a = Data(base64Encoded: left), let b = Data(base64Encoded: right), a.count == 192, b.count == a.count else { return false }
        let errors = zip(a, b).map { abs(Int($0) - Int($1)) }
        return errors.reduce(0, +) <= 16 * errors.count && errors.filter { $0 > 64 }.count <= errors.count / 10
    }
}
