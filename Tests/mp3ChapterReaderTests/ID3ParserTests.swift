import Foundation
import XCTest
@testable import mp3ChapterReader

final class ID3ParserTests: XCTestCase {
    override class func tearDown() {
        super.tearDown()
        RemoteID3TagFetcher.session = .shared
        MockURLProtocol.handler = nil
    }

    func testReadsV23TextFramesFromLocalFile() throws {
        let tagData = makeTag(
            version: 3,
            frames: [
                makeV23Frame("TIT2", body: makeTextBody("Chaptered Book", encoding: 0x00)),
                makeV23Frame("TPE1", body: makeTextBody("Holger Krupp", encoding: 0x00)),
                makeV23Frame("TRCK", body: makeTextBody("2/12", encoding: 0x00))
            ]
        )

        let fileURL = temporaryFileURL()
        try tagData.write(to: fileURL)

        guard let reader = mp3ChapterReader(with: fileURL) else {
            XCTFail("Reader should parse a valid local tag")
            return
        }

        let dict = reader.getID3Dict()
        XCTAssertEqual(dict["TIT2"] as? String, "Chaptered Book")
        XCTAssertEqual(dict["TPE1"] as? String, "Holger Krupp")
        XCTAssertEqual(dict["TRCK"] as? String, "2/12")
    }

    func testReadsV24FramesBeyondLegacySubset() {
        let tagData = makeTag(
            version: 4,
            frames: [
                makeV24Frame("TDRC", body: makeTextBody("2026-03-27", encoding: 0x03)),
                makeV24Frame("TXXX", body: makeUserTextBody(description: "CatalogNumber", values: ["ABC-123"], encoding: 0x03)),
                makeV24Frame("WCOM", body: Data("https://example.com/buy".utf8)),
                makeV24Frame("WXXX", body: makeUserLinkBody(description: "Store", url: "https://example.com/store", encoding: 0x03))
            ]
        )

        guard let reader = mp3ChapterReader(fromData: tagData) else {
            XCTFail("Reader should parse a valid v2.4 tag")
            return
        }

        let dict = reader.getID3Dict()
        XCTAssertEqual(dict["TDRC"] as? String, "2026-03-27")

        let userText = dict["TXXX"] as? [String: Any]
        XCTAssertEqual(userText?["Description"] as? String, "CatalogNumber")
        XCTAssertEqual(userText?["Value"] as? String, "ABC-123")

        XCTAssertEqual(dict["WCOM"] as? String, "https://example.com/buy")

        let userLink = dict["WXXX"] as? [String: Any]
        XCTAssertEqual(userLink?["Description"] as? String, "Store")
        XCTAssertEqual(userLink?["Url"] as? String, "https://example.com/store")
    }

    func testParsesChapterFramesAndTableOfContents() {
        let chapterFrame = makeV23Frame(
            "CHAP",
            body: makeChapterBody(
                elementID: "ch1",
                startTime: 1_000,
                endTime: 5_000,
                subframes: [
                    makeV23Frame("TIT2", body: makeTextBody("Chapter 1", encoding: 0x00)),
                    makeV23Frame("TIT3", body: makeTextBody("Opening", encoding: 0x00)),
                    makeV23Frame("WXXX", body: makeUserLinkBody(description: "Reference", url: "https://example.com/ch1", encoding: 0x00))
                ]
            )
        )

        let tocFrame = makeV23Frame(
            "CTOC",
            body: makeCTOCBody(
                elementID: "toc",
                topLevel: true,
                ordered: true,
                children: ["ch1"],
                subframes: [
                    makeV23Frame("TIT2", body: makeTextBody("Contents", encoding: 0x00))
                ]
            )
        )

        let tagData = makeTag(version: 3, frames: [chapterFrame, tocFrame])

        guard let reader = mp3ChapterReader(fromData: tagData) else {
            XCTFail("Reader should parse chapter tags")
            return
        }

        let dict = reader.getID3Dict()
        let chapters = dict["Chapters"] as? [String: Any]
        let chapter = chapters?["ch1"] as? [String: Any]
        XCTAssertEqual(chapter?["TIT2"] as? String, "Chapter 1")
        XCTAssertEqual(chapter?["TIT3"] as? String, "Opening")
        XCTAssertEqual(chapter?["startTime"] as? Double, 1.0)
        XCTAssertEqual(chapter?["endTime"] as? Double, 5.0)

        let chapterLink = chapter?["WXXX"] as? [String: Any]
        XCTAssertEqual(chapterLink?["Description"] as? String, "Reference")
        XCTAssertEqual(chapterLink?["Url"] as? String, "https://example.com/ch1")

        let tableOfContents = dict["TableOfContents"] as? [String: Any]
        let toc = tableOfContents?["toc"] as? [String: Any]
        XCTAssertEqual(toc?["topLevel"] as? Bool, true)
        XCTAssertEqual(toc?["ordered"] as? Bool, true)
        XCTAssertEqual(toc?["TIT2"] as? String, "Contents")
        XCTAssertEqual((toc?["children"] as? [String]) ?? [], ["ch1"])
    }

    func testMapsID3v22FramesIntoModernFrameIdentifiers() {
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let tagData = makeTag(
            version: 2,
            frames: [
                makeV22Frame("TT2", body: makeTextBody("Legacy Title", encoding: 0x00)),
                makeV22Frame("PIC", body: makeLegacyPictureBody(format: "PNG", pictureType: 0x03, description: "Cover", imageData: imageData))
            ]
        )

        guard let reader = mp3ChapterReader(fromData: tagData) else {
            XCTFail("Reader should parse v2.2 frames")
            return
        }

        let dict = reader.getID3Dict()
        XCTAssertEqual(dict["TIT2"] as? String, "Legacy Title")

        let picture = dict["APIC"] as? [String: Any]
        XCTAssertEqual(picture?["MIME type"] as? String, "image/png")
        XCTAssertEqual(picture?["Description"] as? String, "Cover")
        XCTAssertEqual(picture?["Type"] as? String, PictureType.coverFront.description)
    }

    func testPreservesDuplicateFramesInsteadOfDroppingThem() {
        let tagData = makeTag(
            version: 4,
            frames: [
                makeV24Frame("WCOM", body: Data("https://example.com/one".utf8)),
                makeV24Frame("WCOM", body: Data("https://example.com/two".utf8))
            ]
        )

        guard let reader = mp3ChapterReader(fromData: tagData) else {
            XCTFail("Reader should parse duplicate frames")
            return
        }

        let dict = reader.getID3Dict()
        let values = dict["WCOM"] as? [Any]
        XCTAssertEqual(values?.count, 2)
    }

    func testRemoteReaderUsesRangeFetchAndParsesTag() async throws {
        let tagData = makeTag(
            version: 4,
            frames: [
                makeV24Frame("TIT2", body: makeTextBody("Remote Title", encoding: 0x03))
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        RemoteID3TagFetcher.session = URLSession(configuration: configuration)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!

            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=0-9":
                return (response, tagData.subdata(in: 0..<10))
            case "bytes=0-\(tagData.count - 1)":
                return (response, tagData)
            default:
                XCTFail("Unexpected range request: \(request.value(forHTTPHeaderField: "Range") ?? "nil")")
                return (response, Data())
            }
        }

        let remoteURL = URL(string: "https://example.com/test.mp3")!
        guard let reader = await mp3ChapterReader.fromRemoteURL(remoteURL) else {
            XCTFail("Remote reader should parse fetched tag data")
            return
        }

        XCTAssertEqual(reader.getID3Dict()["TIT2"] as? String, "Remote Title")
    }

    func testRemoteReaderFetchesFullHeaderDeclaredTagWhenItExceedsLegacyDefaultLimit() async throws {
        let imageData = Data(repeating: 0x7B, count: 1_100_000)
        let chapterBody = makeChapterBody(
            elementID: "chapter-image",
            startTime: 0,
            endTime: 10_000,
            subframes: [
                makeV24Frame("TIT2", body: makeTextBody("Image Chapter", encoding: 0x03)),
                makeV24Frame("APIC", body: makePictureBody(mimeType: "image/jpeg", pictureType: 0x03, description: "cover", imageData: imageData))
            ]
        )
        let tagData = makeTag(
            version: 4,
            frames: [
                makeV24Frame("CHAP", body: chapterBody)
            ]
        )

        XCTAssertGreaterThan(tagData.count, 1_024_000)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        RemoteID3TagFetcher.session = URLSession(configuration: configuration)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!

            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=0-9":
                return (response, tagData.subdata(in: 0..<10))
            case "bytes=0-\(tagData.count - 1)":
                return (response, tagData)
            default:
                XCTFail("Unexpected range request: \(request.value(forHTTPHeaderField: "Range") ?? "nil")")
                return (response, Data())
            }
        }

        let remoteURL = URL(string: "https://example.com/large-chapter-image.mp3")!
        guard let reader = await mp3ChapterReader.fromRemoteURL(remoteURL) else {
            XCTFail("Remote reader should parse ID3 tags larger than the legacy default limit")
            return
        }

        let dict = reader.getID3Dict()
        let chapters = dict["Chapters"] as? [String: [String: Any]]
        let chapter = chapters?["chapter-image"]
        XCTAssertEqual(chapter?["TIT2"] as? String, "Image Chapter")

        let apic = chapter?["APIC"] as? [String: Any]
        XCTAssertEqual(apic?["Data"] as? Data, imageData)
    }
}

private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
}

private func makeTag(version: Int, revision: UInt8 = 0, flags: UInt8 = 0, frames: [Data]) -> Data {
    let frameData = frames.reduce(into: Data()) { partial, frame in
        partial.append(frame)
    }

    var tag = Data("ID3".utf8)
    tag.append(UInt8(version))
    tag.append(revision)
    tag.append(flags)
    tag.append(contentsOf: synchsafe(frameData.count))
    tag.append(frameData)
    return tag
}

private func makeV23Frame(_ id: String, body: Data, flags: (UInt8, UInt8) = (0, 0)) -> Data {
    var frame = Data(id.utf8)
    frame.append(contentsOf: uint32BE(body.count))
    frame.append(flags.0)
    frame.append(flags.1)
    frame.append(body)
    return frame
}

private func makeV24Frame(_ id: String, body: Data, flags: (UInt8, UInt8) = (0, 0)) -> Data {
    var frame = Data(id.utf8)
    frame.append(contentsOf: synchsafe(body.count))
    frame.append(flags.0)
    frame.append(flags.1)
    frame.append(body)
    return frame
}

private func makeV22Frame(_ id: String, body: Data) -> Data {
    var frame = Data(id.utf8)
    frame.append(contentsOf: uint24BE(body.count))
    frame.append(body)
    return frame
}

private func makeTextBody(_ value: String, encoding: UInt8) -> Data {
    makeTextBody([value], encoding: encoding)
}

private func makeTextBody(_ values: [String], encoding: UInt8) -> Data {
    var body = Data([encoding])
    let terminator = textTerminator(for: encoding)

    for (index, value) in values.enumerated() {
        body.append(encodedString(value, encoding: encoding))
        if index < values.count - 1 {
            body.append(terminator)
        }
    }

    return body
}

private func makeUserTextBody(description: String, values: [String], encoding: UInt8) -> Data {
    var body = Data([encoding])
    body.append(encodedString(description, encoding: encoding))
    body.append(textTerminator(for: encoding))

    for (index, value) in values.enumerated() {
        body.append(encodedString(value, encoding: encoding))
        if index < values.count - 1 {
            body.append(textTerminator(for: encoding))
        }
    }

    return body
}

private func makeUserLinkBody(description: String, url: String, encoding: UInt8) -> Data {
    var body = Data([encoding])
    body.append(encodedString(description, encoding: encoding))
    body.append(textTerminator(for: encoding))
    body.append(Data(url.utf8))
    return body
}

private func makeLegacyPictureBody(format: String, pictureType: UInt8, description: String, imageData: Data) -> Data {
    var body = Data([0x00])
    body.append(Data(format.utf8.prefix(3)))
    body.append(pictureType)
    body.append(Data(description.utf8))
    body.append(0x00)
    body.append(imageData)
    return body
}

private func makePictureBody(mimeType: String, pictureType: UInt8, description: String, imageData: Data) -> Data {
    var body = Data([0x03])
    body.append(Data(mimeType.utf8))
    body.append(0x00)
    body.append(pictureType)
    body.append(Data(description.utf8))
    body.append(0x00)
    body.append(imageData)
    return body
}

private func makeChapterBody(
    elementID: String,
    startTime: UInt32,
    endTime: UInt32,
    startOffset: UInt32 = UInt32.max,
    endOffset: UInt32 = UInt32.max,
    subframes: [Data]
) -> Data {
    var body = Data(elementID.utf8)
    body.append(0x00)
    body.append(contentsOf: uint32BE(Int(startTime)))
    body.append(contentsOf: uint32BE(Int(endTime)))
    body.append(contentsOf: uint32BE(Int(startOffset)))
    body.append(contentsOf: uint32BE(Int(endOffset)))
    for frame in subframes {
        body.append(frame)
    }
    return body
}

private func makeCTOCBody(
    elementID: String,
    topLevel: Bool,
    ordered: Bool,
    children: [String],
    subframes: [Data]
) -> Data {
    var body = Data(elementID.utf8)
    body.append(0x00)

    var flags: UInt8 = 0
    if topLevel {
        flags |= 0x02
    }
    if ordered {
        flags |= 0x01
    }
    body.append(flags)
    body.append(UInt8(children.count))

    for child in children {
        body.append(Data(child.utf8))
        body.append(0x00)
    }

    for frame in subframes {
        body.append(frame)
    }

    return body
}

private func encodedString(_ value: String, encoding: UInt8) -> Data {
    switch encoding {
    case 0x00:
        return Data(value.data(using: .isoLatin1) ?? Data())
    case 0x01:
        let bom = Data([0xFF, 0xFE])
        return bom + Data(value.data(using: .utf16LittleEndian) ?? Data())
    case 0x02:
        return Data(value.data(using: .utf16BigEndian) ?? Data())
    default:
        return Data(value.utf8)
    }
}

private func textTerminator(for encoding: UInt8) -> Data {
    switch encoding {
    case 0x01, 0x02:
        return Data([0x00, 0x00])
    default:
        return Data([0x00])
    }
}

private func synchsafe(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 21) & 0x7F),
        UInt8((value >> 14) & 0x7F),
        UInt8((value >> 7) & 0x7F),
        UInt8(value & 0x7F)
    ]
}

private func uint32BE(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

private func uint24BE(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
