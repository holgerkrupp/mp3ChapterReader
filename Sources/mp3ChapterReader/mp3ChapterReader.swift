import Foundation

public struct ID3Tag: Sendable {
    public let version: Int
    public let revision: Int
    public let frames: [Frame]
    public let chapters: [ChapFrame]
}

public class mp3ChapterReader {
    private var fileData: Data

    public var frames: [Frame] = []

    public var version: Int = 0
    public var revision: Int = 0

    public var hasExtendedHeader: Bool = false
    public var isExperimental: Bool = false
    public var hasFooter: Bool = false
    public var hasUnsynchronization: Bool = false
    public var isCompressedTag: Bool = false

    public var tagSize: Int = 0

    public var chapters: [ChapFrame] {
        frames.compactMap { $0 as? ChapFrame }
    }

    public var tablesOfContents: [CTOCFrame] {
        frames.compactMap { $0 as? CTOCFrame }
    }

    public init?(with fileURL: URL) {
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            print("Error reading file: \(error)")
            return nil
        }

        guard parseHeader(from: fileData) else {
            return nil
        }

        frames = extractID3Frames()
    }

    public init?(fromData data: Data) {
        fileData = data

        guard parseHeader(from: data) else {
            return nil
        }

        frames = extractID3Frames()
    }

    public static func fromRemoteURL(_ remoteURL: URL, maxTagSize: Int? = nil) async -> mp3ChapterReader? {
        do {
            let tagData = try await RemoteID3TagFetcher.fetchID3Tag(from: remoteURL, maxSize: maxTagSize)
            return mp3ChapterReader(fromData: tagData)
        } catch {
            print("Remote ID3 tag fetch failed: \(error)")
            return nil
        }
    }

    public func getID3Dict() -> [String: Any] {
        convertFramesToDictionary(frames)
    }

    public func getID3Tag() -> ID3Tag {
        ID3Tag(version: version, revision: revision, frames: frames, chapters: chapters)
    }

    private func parseHeader(from data: Data) -> Bool {
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else {
            print("Not an ID3v2 tag.")
            return false
        }

        version = Int(data[3])
        revision = Int(data[4])

        guard version >= 2 && version <= 4 else {
            print("Unsupported ID3v2 version: \(version)")
            return false
        }

        let flags = data[5]
        hasUnsynchronization = (flags & 0x80) != 0

        switch version {
        case 2:
            isCompressedTag = (flags & 0x40) != 0
            hasExtendedHeader = false
            isExperimental = false
            hasFooter = false
        case 3:
            hasExtendedHeader = (flags & 0x40) != 0
            isExperimental = (flags & 0x20) != 0
            hasFooter = false
        default:
            hasExtendedHeader = (flags & 0x40) != 0
            isExperimental = (flags & 0x20) != 0
            hasFooter = (flags & 0x10) != 0
        }

        tagSize = data.readSynchsafeInt(at: 6)
        return true
    }

    private func convertFramesToDictionary(_ frames: [Frame]) -> [String: Any] {
        var framesDictionary: [String: Any] = [:]
        var chaptersDictionary: [String: Any] = [:]
        var tablesOfContentsDictionary: [String: Any] = [:]

        for frame in frames {
            if let chapterFrame = frame as? ChapFrame {
                chaptersDictionary[chapterFrame.elementID] = chapterFrame.createDictionary()
                continue
            }

            if let tocFrame = frame as? CTOCFrame {
                tablesOfContentsDictionary[tocFrame.elementID] = tocFrame.createDictionary()
                continue
            }

            mergeFrameDictionary(into: &framesDictionary, frameDictionary: frame.createDictionary())
        }

        if !chaptersDictionary.isEmpty {
            framesDictionary["Chapters"] = chaptersDictionary
        }
        if !tablesOfContentsDictionary.isEmpty {
            framesDictionary["TableOfContents"] = tablesOfContentsDictionary
        }

        return framesDictionary
    }

    private func extractID3Frames() -> [Frame] {
        if version == 2 && isCompressedTag {
            print("Compressed ID3v2.2 tags are not supported.")
            return []
        }

        var currentPosition = 10

        if hasExtendedHeader {
            if version == 4 {
                let extendedHeaderSize = fileData.readSynchsafeInt(at: currentPosition)
                currentPosition += extendedHeaderSize
            } else if version == 3 {
                let extendedHeaderSize = Int(fileData.readUInt32BigEndian(at: currentPosition))
                currentPosition += extendedHeaderSize + 4
            }
        }

        let tagEnd = min(10 + tagSize, fileData.count)
        guard currentPosition < tagEnd else {
            return []
        }

        let frameData = fileData.subdata(in: currentPosition..<tagEnd)
        return ID3FrameParser.parseFrames(
            in: frameData,
            version: version,
            tagUnsynchronization: hasUnsynchronization
        )
    }
}

public enum RemoteID3TagFetcherError: Error {
    case invalidHeader
    case unsupportedFormat
    case tagTooLarge(Int)
    case networkError(Error)
}

public enum RemoteMP3DurationReaderError: Error {
    case missingContentLength
    case noMP3FrameFound
    case unsupportedMP3Frame
    case networkError(Error)
}

public struct RemoteMP3DurationReader {
    public static func duration(from url: URL, frameSearchByteCount: Int = 64 * 1024) async throws -> TimeInterval {
        let contentLength = try await fetchContentLength(from: url)
        let audioStartOffset = await audioStartOffset(from: url)
        let searchData = try await fetchBytes(
            from: url,
            range: audioStartOffset..<(audioStartOffset + Int64(frameSearchByteCount))
        )

        guard let frame = firstMP3Frame(in: searchData) else {
            throw RemoteMP3DurationReaderError.noMP3FrameFound
        }

        guard frame.bitRate > 0, contentLength > audioStartOffset else {
            throw RemoteMP3DurationReaderError.unsupportedMP3Frame
        }

        let audioByteCount = contentLength - audioStartOffset
        return TimeInterval(Double(audioByteCount * 8) / Double(frame.bitRate))
    }

    private static func audioStartOffset(from url: URL) async -> Int64 {
        guard let reader = await mp3ChapterReader.fromRemoteURL(url, maxTagSize: 2 * 1024 * 1024) else {
            return 0
        }

        return Int64(10 + reader.tagSize + (reader.hasFooter ? 10 : 0))
    }

    private static func fetchContentLength(from url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await RemoteID3TagFetcher.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteMP3DurationReaderError.missingContentLength
            }

            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let value = Int64(contentLength),
               value > 0 {
                return value
            }

            if httpResponse.expectedContentLength > 0 {
                return httpResponse.expectedContentLength
            }

            throw RemoteMP3DurationReaderError.missingContentLength
        } catch let error as RemoteMP3DurationReaderError {
            throw error
        } catch {
            throw RemoteMP3DurationReaderError.networkError(error)
        }
    }

    private static func fetchBytes(from url: URL, range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        do {
            let (data, _) = try await RemoteID3TagFetcher.session.data(for: request)
            return data
        } catch {
            throw RemoteMP3DurationReaderError.networkError(error)
        }
    }

    private static func firstMP3Frame(in data: Data) -> MP3FrameInfo? {
        guard data.count >= 4 else { return nil }

        var index = 0
        while index <= data.count - 4 {
            if let frame = MP3FrameInfo(data: data, offset: index) {
                return frame
            }
            index += 1
        }

        return nil
    }
}

private struct MP3FrameInfo {
    let bitRate: Int

    init?(data: Data, offset: Int) {
        guard offset + 3 < data.count else { return nil }

        let byte0 = data[offset]
        let byte1 = data[offset + 1]
        let byte2 = data[offset + 2]

        guard byte0 == 0xFF, (byte1 & 0xE0) == 0xE0 else { return nil }

        let versionBits = (byte1 >> 3) & 0x03
        let layerBits = (byte1 >> 1) & 0x03
        let bitrateIndex = (byte2 >> 4) & 0x0F
        let sampleRateIndex = (byte2 >> 2) & 0x03

        guard versionBits != 0x01,
              layerBits != 0x00,
              bitrateIndex != 0x00,
              bitrateIndex != 0x0F,
              sampleRateIndex != 0x03 else {
            return nil
        }

        let mpegVersion: MPEGVersion
        switch versionBits {
        case 0x03: mpegVersion = .version1
        case 0x02: mpegVersion = .version2
        default: mpegVersion = .version25
        }

        let layer: MPEGLayer
        switch layerBits {
        case 0x03: layer = .layer1
        case 0x02: layer = .layer2
        default: layer = .layer3
        }

        guard let kiloBitsPerSecond = Self.bitrateKilobitsPerSecond(
            version: mpegVersion,
            layer: layer,
            index: Int(bitrateIndex)
        ) else {
            return nil
        }

        bitRate = kiloBitsPerSecond * 1000
    }

    private static func bitrateKilobitsPerSecond(version: MPEGVersion, layer: MPEGLayer, index: Int) -> Int? {
        let table: [Int]

        switch (version, layer) {
        case (.version1, .layer1):
            table = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        case (.version1, .layer2):
            table = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        case (.version1, .layer3):
            table = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        case (_, .layer1):
            table = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
        case (_, .layer2), (_, .layer3):
            table = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        }

        guard table.indices.contains(index) else { return nil }
        return table[index]
    }
}

private enum MPEGVersion {
    case version1
    case version2
    case version25
}

private enum MPEGLayer {
    case layer1
    case layer2
    case layer3
}

public struct RemoteID3TagFetcher {
    static var session: URLSession = .shared

    public static func fetchID3Tag(from url: URL, maxSize: Int? = nil) async throws -> Data {
        let header = try await fetchBytes(from: url, range: 0..<10)

        guard header.starts(with: [0x49, 0x44, 0x33]) else {
            throw RemoteID3TagFetcherError.invalidHeader
        }

        let tagSize = header.readSynchsafeInt(at: 6)
        let totalSize = 10 + tagSize

        if let maxSize, totalSize > maxSize {
            throw RemoteID3TagFetcherError.tagTooLarge(totalSize)
        }

        return try await fetchBytes(from: url, range: 0..<totalSize)
    }

    private static func fetchBytes(from url: URL, range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            throw RemoteID3TagFetcherError.networkError(error)
        }
    }
}
