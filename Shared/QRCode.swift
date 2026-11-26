import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

enum QRCode {
    static let placeholder = "https://hgsldswk-alt.github.io/sellordonate-support/"

    static func downloadLink(appStoreID: String?) -> String {
        guard let appStoreID, !appStoreID.isEmpty,
              appStoreID.utf8.allSatisfy({ (48...57).contains($0) }) else { return placeholder }
        return "https://apps.apple.com/app/id" + appStoreID
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let source = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent) else { return nil }
        let scale = 8
        let margin = 4 * scale
        let modules = source.width
        let pixels = modules * scale
        let size = pixels + 2 * margin
        guard let target = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                     bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        target.setFillColor(gray: 1, alpha: 1)
        target.fill(CGRect(x: 0, y: 0, width: size, height: size))
        target.interpolationQuality = .none
        target.draw(source, in: CGRect(x: margin, y: margin, width: pixels, height: pixels))
        return target.makeImage()
    }
}
