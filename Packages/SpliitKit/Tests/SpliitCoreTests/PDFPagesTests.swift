import CoreGraphics
import Foundation
import Testing

@testable import SpliitCore

/// Every PDF here is made by the test, either by CoreGraphics or written out by hand, so what each
/// one contains is stated where it is used rather than hidden in a binary fixture.
@Suite("Drawing a PDF's pages")
struct PDFPagesTests {

    @Test("Every page of a short PDF is drawn")
    func drawsEveryPage() throws {
        let pages = try PDFPages(data: Self.pdf(pages: 2))
        #expect(pages.pageCount == 2)
        #expect(pages.count == 2)
        #expect(pages.image(ofPage: 0) != nil)
        #expect(pages.image(ofPage: 1) != nil)
        #expect(pages.image(ofPage: 2) == nil)
    }

    /// The rest are left out rather than the file refused, and the page count is what lets the form
    /// say so.
    @Test("A long PDF is cut to the first five pages")
    func capsThePages() throws {
        let pages = try PDFPages(data: Self.pdf(pages: 7))
        #expect(pages.pageCount == 7)
        #expect(pages.count == PDFPages.maximumPages)
        #expect(pages.image(ofPage: PDFPages.maximumPages - 1) != nil)
        #expect(pages.image(ofPage: PDFPages.maximumPages) == nil)
    }

    /// The reason the transform is built by hand: `getDrawingTransform` would have left a Letter
    /// page at 612 by 792.
    @Test("A Letter page is scaled up to the longest side")
    func scalesUp() throws {
        let image = try #require(PDFPages(data: Self.pdf(pages: 1)).image(ofPage: 0))
        #expect(image.height == PDFPages.longestSide)
        #expect((1582...1584).contains(image.width))
    }

    @Test("A landscape page comes out wider than it is tall")
    func keepsLandscape() throws {
        let landscape = CGRect(x: 0, y: 0, width: 792, height: 612)
        let image = try #require(
            PDFPages(data: Self.pdf(pages: 1, mediaBox: landscape)).image(ofPage: 0)
        )
        #expect(image.width == PDFPages.longestSide)
        #expect(image.height < image.width)
    }

    /// The page has a black band across its top, and the band has to end up where the top of the
    /// page does once `/Rotate` has turned it — which is the one thing that says the transform
    /// turns the right way, rather than merely giving the right size.
    @Test(
        "A rotated page is drawn the way it is shown",
        arguments: [(0, PageEdge.top), (90, .right), (180, .bottom), (270, .left)]
    )
    func honoursRotation(rotation: Int, bandEdge: PageEdge) throws {
        let image = try #require(
            PDFPages(data: Self.handWrittenPDF(rotation: rotation)).image(ofPage: 0)
        )
        let isQuarterTurn = rotation == 90 || rotation == 270
        #expect((isQuarterTurn ? image.width : image.height) == PDFPages.longestSide)
        #expect(isQuarterTurn ? image.width > image.height : image.height > image.width)

        let pixels = try Grayscale(image)
        #expect(pixels.lightness(near: bandEdge) < 64)
        #expect(pixels.lightness(near: bandEdge.opposite) > 191)
    }

    /// A PDF page has no background, and the JPEG it is about to become would turn that black.
    @Test("An empty page is white, not black")
    func fillsWhite() throws {
        let image = try #require(PDFPages(data: Self.pdf(pages: 1)).image(ofPage: 0))
        let pixels = try Grayscale(image)
        #expect(pixels[0, 0] > 250)
        #expect(pixels[image.width - 1, image.height - 1] > 250)
    }

    @Test("Something that is not a PDF is unreadable")
    func refusesGarbage() {
        #expect(throws: PDFPages.Failure.unreadable) {
            try PDFPages(data: Data("This is not a PDF.".utf8))
        }
        #expect(throws: PDFPages.Failure.unreadable) {
            try PDFPages(data: Data())
        }
    }

    /// Booking sites send these: encrypted so as to forbid printing or copying, with no password
    /// needed to read them.
    @Test("A PDF with only an owner password opens")
    func opensWithoutAUserPassword() throws {
        let data = try Self.pdf(pages: 1, options: [kCGPDFContextOwnerPassword: "owner"])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.isEncrypted)

        #expect(try PDFPages(data: data).image(ofPage: 0) != nil)
    }

    @Test("A PDF that needs a password to read is locked")
    func refusesALockedPDF() throws {
        let data = try Self.pdf(
            pages: 1,
            options: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: "user"]
        )
        #expect(throws: PDFPages.Failure.locked) {
            try PDFPages(data: data)
        }
    }

    // MARK: - Making PDFs

    private static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// Blank pages, drawn by CoreGraphics. `options` is the auxiliary dictionary a PDF context
    /// takes, which is where its passwords go.
    private static func pdf(
        pages: Int, mediaBox: CGRect = letter, options: [CFString: Any] = [:]
    ) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = mediaBox
        let context = try #require(
            CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary)
        )
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// One Letter page with a black band 50 points deep across the top, written out by hand
    /// because a PDF context has no way to set a page's `/Rotate`.
    private static func handWrittenPDF(rotation: Int) -> Data {
        let content = "0 g 0 742 612 50 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation)"
                + " /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        // Each entry in the cross-reference table is exactly twenty bytes, trailing space
        // included, and says where its object starts.
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010ld 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

enum PageEdge: Sendable, CustomTestStringConvertible {
    case top, right, bottom, left

    var opposite: PageEdge {
        switch self {
        case .top: .bottom
        case .right: .left
        case .bottom: .top
        case .left: .right
        }
    }

    var testDescription: String {
        switch self {
        case .top: "the top"
        case .right: "the right"
        case .bottom: "the bottom"
        case .left: "the left"
        }
    }
}

/// A picture redrawn as one byte of grey per pixel, so a test can ask how light it is somewhere.
/// Rows run from the top, as they do in the picture.
private struct Grayscale {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let bytesPerRow: Int

    init(_ image: CGImage) throws {
        let context = try #require(
            CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let start = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        width = image.width
        height = image.height
        bytesPerRow = context.bytesPerRow
        bytes = Array(UnsafeBufferPointer(start: start, count: bytesPerRow * height))
    }

    subscript(x: Int, y: Int) -> UInt8 { bytes[y * bytesPerRow + x] }

    /// Twenty pixels in from the middle of an edge: well inside a band 50 points deep, which is
    /// about 130 pixels once the page is drawn.
    func lightness(near edge: PageEdge) -> UInt8 {
        switch edge {
        case .top: self[width / 2, 20]
        case .bottom: self[width / 2, height - 21]
        case .left: self[20, height / 2]
        case .right: self[width - 21, height / 2]
        }
    }
}
