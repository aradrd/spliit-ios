import CoreGraphics
import Foundation

/// The pages of a PDF, drawn as pictures — which is the only form in which a PDF can be kept with
/// an expense.
///
/// The web app takes JPEG and PNG and nothing else, and draws every document as an image with the
/// width and height stored beside it. A PDF uploaded as it is would be a broken picture there, so
/// an e-receipt or a booking confirmation is attached the way a photograph is: each page drawn on
/// the phone, then re-encoded and uploaded like any other picture. Both products then show the same
/// thing, and no instance needs to change to accept it.
///
/// Holds the file rather than the parsed document, and opens it again for every page. That is what
/// makes it `Sendable`, so each page can be drawn off the main actor on its own; reading a PDF's
/// cross-reference table a second time is nothing beside drawing a page at 2048 pixels.
public struct PDFPages: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// Not a PDF, or one with no pages in it.
        case unreadable
        /// Opening it needs a password nobody has given us. Said apart from `unreadable` because
        /// the fix is different: the file is fine, it is the lock that has to come off.
        case locked
    }

    /// The pages drawn from any one file. A PDF can have hundreds, and an expense wants the
    /// receipt rather than the terms and conditions behind it — five is also what the photo picker
    /// lets somebody choose at once. The rest are left out rather than the file refused, and
    /// `pageCount` says how many there were so the form can say so.
    public static let maximumPages = 5

    /// The size of the longest side of each page, in pixels. The same cap `DocumentImage` puts on a
    /// photograph, so the page reaches it already the size it would have been redrawn to.
    public static let longestSide = 2048

    /// Every page in the file, including the ones past `maximumPages`.
    public let pageCount: Int

    /// How many pages will be drawn.
    public var count: Int { min(pageCount, Self.maximumPages) }

    private let data: Data

    public init(data: Data) throws {
        let document = try Self.open(data)
        self.data = data
        self.pageCount = document.numberOfPages
    }

    /// One page, counted from zero, as an opaque picture with nothing behind it but white. Nil for
    /// a page past `count`, or one with no area to draw.
    ///
    /// Drawn one at a time, on purpose: a page at full size is about thirteen megabytes of
    /// pixels, and holding five of them at once is a price a receipt is not worth paying.
    public func image(ofPage index: Int) -> CGImage? {
        guard (0..<count).contains(index),
              let document = try? Self.open(data),
              let page = document.page(at: index + 1)
        else {
            return nil
        }
        return Self.draw(page)
    }

    private static func open(_ data: Data) throws -> CGPDFDocument {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else {
            throw Failure.unreadable
        }
        // A PDF encrypted with only an owner password — the kind that forbids printing or copying
        // but not reading, and which plenty of booking sites send — opens with an empty user
        // password. CoreGraphics usually tries that itself; asking again costs nothing.
        if !document.isUnlocked {
            _ = document.unlockWithPassword("")
        }
        guard document.isUnlocked else { throw Failure.locked }
        guard document.numberOfPages > 0 else { throw Failure.unreadable }
        return document
    }

    /// Draws a page at `longestSide`, the right way up.
    ///
    /// The transform is built here rather than taken from `getDrawingTransform`, which only ever
    /// scales *down*: a Letter page is 612 by 792 points, and it would leave one at about a third
    /// of the size a photograph of the same receipt would have — too small to read the small print
    /// on. It also honours the page's rotation, which drawing the page as it is does not: a page
    /// whose `/Rotate` turns it to landscape is stored in portrait.
    private static func draw(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let isQuarterTurn = rotation == 90 || rotation == 270
        let width = isQuarterTurn ? box.height : box.width
        let height = isQuarterTurn ? box.width : box.height
        let scale = CGFloat(longestSide) / max(width, height)
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high

        // A PDF page has no background: what looks like white paper is nothing at all, and nothing
        // becomes black on its way into a JPEG. So the paper is put in first.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.scaleBy(x: scale, y: scale)
        // `/Rotate` turns the page clockwise as it is shown, and these coordinates run upwards, so
        // clockwise is the negative direction. Each case puts the turned page back on the canvas.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)

        return context.makeImage()
    }
}
