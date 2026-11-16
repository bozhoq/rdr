import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Identical CPU-only artwork on iPhone and in the macOS preview test.
/// Core Graphics/Core Text avoid a Metal device dependency during export.
enum CardArtwork {
    static func render(_ data: SessionCardData) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1080, height: 1440,
                  bitsPerComponent: 8, bytesPerRow: 1080 * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 3, y: 3)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let foam = CGColor(red: 0.82, green: 1, blue: 0.95, alpha: 1)
        let colors = [CGColor(red: 0.01, green: 0.32, blue: 0.43, alpha: 1),
                      CGColor(red: 0, green: 0.48, blue: 0.44, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 480), end: CGPoint(x: 360, y: 0), options: [])

        func text(_ value: String, x: CGFloat = 28, top: CGFloat, width: CGFloat = 304,
                  height: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor? = nil, fit: Bool = false) {
            var pointSize = size
            var attributed: NSAttributedString
            while true {
                let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, pointSize, nil)
                attributed = NSAttributedString(string: value, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? white
                ])
                let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                if !fit || CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(width) || pointSize <= size * 0.65 { break }
                pointSize -= 0.5
            }
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let path = CGPath(rect: CGRect(x: x, y: 480 - top - height, width: width, height: height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
            CTFrameDraw(frame, context)
        }

        text("RDR", top: 24, width: 170, height: 52, size: 38, bold: true)
        text("Rider", x: 265, top: 42, width: 70, height: 30, size: 20, bold: true)
        text(data.sport, top: 101, height: 38, size: 25, bold: true, fit: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        text(formatter.string(from: data.date), top: 140, height: 24, size: 14, color: foam)
        let duration = Int(max(0, data.duration))
        text(String(format: "%02d:%02d:%02d", duration / 3600, duration / 60 % 60, duration % 60), top: 181, height: 55, size: 42, bold: true, fit: true)
        text("Дистанция GPS", top: 254, width: 143, height: 23, size: 12, color: foam)
        text("Максимум GPS", x: 190, top: 254, width: 143, height: 23, size: 12, color: foam)
        text(number(data.distanceMeters.map { $0 / 1000 }, unit: "км", digits: 2), top: 280, width: 143, height: 32, size: 23, bold: true, fit: true)
        text(number(data.speedMetersPerSecond.map { $0 * 3.6 }, unit: "км/ч"), x: 190, top: 280, width: 143, height: 32, size: 23, bold: true, fit: true)
        context.setStrokeColor(white.copy(alpha: 0.25)!)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 28, y: 480 - 330))
        context.addLine(to: CGPoint(x: 332, y: 480 - 330))
        context.strokePath()
        text("Прыжков отмечено мной: \(data.markedJumps)", top: 350, height: 26, size: 17, bold: true, fit: true)
        text("Событий детектора: \(data.candidateCount)", top: 384, height: 24, size: 15, color: foam, fit: true)
        text("GPS приблизительный · детектор экспериментальный\nВысота и время полёта не измерены", top: 434, height: 34, size: 10.5, color: foam)
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    private static func number(_ value: Double?, unit: String, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(digits))) + " " + unit
    }
}
