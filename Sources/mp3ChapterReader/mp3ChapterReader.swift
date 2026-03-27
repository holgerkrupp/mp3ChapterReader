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

    public static func fromRemoteURL(_ remoteURL: URL, maxTagSize: Int = 1_024_000) async -> mp3ChapterReader? {
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

public struct RemoteID3TagFetcher {
    static var session: URLSession = .shared

    public static func fetchID3Tag(from url: URL, maxSize: Int = 1_024_000) async throws -> Data {
        let header = try await fetchBytes(from: url, range: 0..<10)

        guard header.starts(with: [0x49, 0x44, 0x33]) else {
            throw RemoteID3TagFetcherError.invalidHeader
        }

        let tagSize = header.readSynchsafeInt(at: 6)
        let totalSize = 10 + tagSize

        guard totalSize <= maxSize else {
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
