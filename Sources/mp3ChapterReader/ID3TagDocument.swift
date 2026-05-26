import Foundation

public enum ID3TagDocumentError: Error, LocalizedError {
    case unsupportedWriteVersion(Int)
    case invalidFrameIdentifier(String)
    case invalidTagSize(Int)
    case encryptedOrCompressedEditedFrame(String)
    case tooManyTableOfContentsChildren(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedWriteVersion(let version):
            return "ID3v2.\(version) writing is not supported. Only ID3v2.3 and ID3v2.4 can be written."
        case .invalidFrameIdentifier(let identifier):
            return "Invalid ID3 frame identifier: \(identifier)."
        case .invalidTagSize(let size):
            return "ID3 tag size \(size) cannot be represented as a synchsafe integer."
        case .encryptedOrCompressedEditedFrame(let identifier):
            return "Frame \(identifier) is encrypted or compressed and cannot be edited by this writer."
        case .tooManyTableOfContentsChildren(let count):
            return "CTOC contains \(count) children, but ID3 stores the child count in one byte."
        }
    }
}

public struct ID3Picture: Equatable, Sendable {
    public var mimeType: String
    public var type: PictureType
    public var description: String
    public var data: Data

    public init(mimeType: String, type: PictureType = .coverFront, description: String = "", data: Data) {
        self.mimeType = mimeType
        self.type = type
        self.description = description
        self.data = data
    }
}

public struct ID3Chapter: Equatable, Sendable {
    public var elementID: String
    public var startTimeMilliseconds: UInt32
    public var endTimeMilliseconds: UInt32
    public var startOffset: UInt32
    public var endOffset: UInt32
    public var subframes: [ID3MutableFrame]

    public init(
        elementID: String,
        startTimeMilliseconds: UInt32,
        endTimeMilliseconds: UInt32,
        startOffset: UInt32 = UInt32.max,
        endOffset: UInt32 = UInt32.max,
        subframes: [ID3MutableFrame] = []
    ) {
        self.elementID = elementID
        self.startTimeMilliseconds = startTimeMilliseconds
        self.endTimeMilliseconds = endTimeMilliseconds
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.subframes = subframes
    }
}

public struct ID3TableOfContents: Equatable, Sendable {
    public var elementID: String
    public var isTopLevel: Bool
    public var isOrdered: Bool
    public var childElementIDs: [String]
    public var subframes: [ID3MutableFrame]

    public init(
        elementID: String = "toc",
        isTopLevel: Bool = true,
        isOrdered: Bool = true,
        childElementIDs: [String],
        subframes: [ID3MutableFrame] = []
    ) {
        self.elementID = elementID
        self.isTopLevel = isTopLevel
        self.isOrdered = isOrdered
        self.childElementIDs = childElementIDs
        self.subframes = subframes
    }
}

public enum ID3MutableFrame: Equatable, Sendable {
    case text(id: String, values: [String])
    case url(id: String, url: String, description: String?)
    case picture(ID3Picture)
    case chapter(ID3Chapter)
    case tableOfContents(ID3TableOfContents)
    case raw(id: String, flags: FrameFlags, body: Data)

    public static func text(id: String, value: String) -> ID3MutableFrame {
        .text(id: id, values: [value])
    }

    public var id: String {
        switch self {
        case .text(let id, _), .url(let id, _, _), .raw(let id, _, _):
            return id
        case .picture:
            return "APIC"
        case .chapter:
            return "CHAP"
        case .tableOfContents:
            return "CTOC"
        }
    }
}

public struct ID3TagDocument: Sendable {
    public private(set) var version: Int
    public private(set) var revision: Int
    public var frames: [ID3MutableFrame]
    public private(set) var audioPayload: Data

    public init(version: Int = 4, frames: [ID3MutableFrame] = [], audioPayload: Data = Data()) {
        self.version = version
        self.revision = 0
        self.frames = frames
        self.audioPayload = audioPayload
    }

    public init(data: Data) {
        if data.count >= 10, data.prefix(3) == Data("ID3".utf8), let reader = mp3ChapterReader(fromData: data) {
            version = reader.version == 3 ? 3 : 4
            revision = reader.revision
            frames = reader.frames.map(ID3MutableFrame.init(frame:))

            let footerSize = reader.hasFooter ? 10 : 0
            let payloadStart = min(10 + reader.tagSize + footerSize, data.count)
            audioPayload = data.subdata(in: payloadStart..<data.count)
        } else {
            version = 4
            revision = 0
            frames = []
            audioPayload = data
        }
    }

    public init(fileURL: URL) throws {
        self.init(data: try Data(contentsOf: fileURL))
    }

    public mutating func setTextFrame(_ id: String, value: String) {
        removeFrames(id: id)
        frames.append(.text(id: id, values: [value]))
    }

    public mutating func removeTextFrame(_ id: String) {
        frames.removeAll { frame in
            if case .text(let frameID, _) = frame {
                return frameID == id
            }
            return false
        }
    }

    public mutating func setURLFrame(_ id: String, url: String, description: String? = nil) {
        removeURLFrame(id, description: description)
        frames.append(.url(id: id, url: url, description: description))
    }

    public mutating func removeURLFrame(_ id: String, description: String? = nil) {
        frames.removeAll { frame in
            guard case .url(let frameID, _, let frameDescription) = frame, frameID == id else {
                return false
            }
            return description == nil || frameDescription == description
        }
    }

    public mutating func setPictureFrame(_ picture: ID3Picture) {
        removePictureFrames()
        frames.append(.picture(picture))
    }

    public mutating func removePictureFrames() {
        frames.removeAll {
            if case .picture = $0 {
                return true
            }
            return $0.id == "APIC"
        }
    }

    public mutating func replaceChapters(_ chapters: [ID3Chapter], tableOfContents: ID3TableOfContents? = nil) {
        frames.removeAll { $0.id == "CHAP" || $0.id == "CTOC" }
        frames.append(contentsOf: chapters.map { .chapter($0) })

        if let tableOfContents {
            frames.append(.tableOfContents(tableOfContents))
        } else if !chapters.isEmpty {
            frames.append(.tableOfContents(ID3TableOfContents(
                childElementIDs: chapters.map(\.elementID),
                subframes: [.text(id: "TIT2", value: "Chapters")]
            )))
        }
    }

    public func serializedMP3Data() throws -> Data {
        let writerVersion = version == 3 ? 3 : 4
        guard writerVersion == 3 || writerVersion == 4 else {
            throw ID3TagDocumentError.unsupportedWriteVersion(version)
        }

        let frameData = try ID3FrameSerializer.serialize(frames: frames, version: writerVersion)
        guard frameData.count <= 0x0FFF_FFFF else {
            throw ID3TagDocumentError.invalidTagSize(frameData.count)
        }

        var tag = Data("ID3".utf8)
        tag.append(UInt8(writerVersion))
        tag.append(UInt8(revision))
        tag.append(0x00)
        tag.append(contentsOf: ID3FrameSerializer.synchsafeBytes(frameData.count))
        tag.append(frameData)
        tag.append(audioPayload)
        return tag
    }

    public func write(to url: URL) throws {
        try serializedMP3Data().write(to: url)
    }

    private mutating func removeFrames(id: String) {
        frames.removeAll { $0.id == id }
    }
}

extension ID3MutableFrame {
    init(frame: Frame) {
        if frame.flags.isEncrypted || frame.flags.isCompressed {
            self = .raw(id: frame.frameID, flags: frame.flags, body: frame.rawBody)
        } else if let textFrame = frame as? TextFrame {
            self = .text(id: textFrame.frameID, values: textFrame.values)
        } else if let linkFrame = frame as? LinkFrame {
            self = .url(
                id: linkFrame.frameID,
                url: linkFrame.urlString ?? "",
                description: linkFrame.userDefined ? linkFrame.descriptionText : nil
            )
        } else if let pictureFrame = frame as? PictureFrame {
            self = .picture(ID3Picture(
                mimeType: pictureFrame.mimeType ?? "application/octet-stream",
                type: pictureFrame.type ?? .other,
                description: pictureFrame.descriptionText ?? "",
                data: pictureFrame.image ?? Data()
            ))
        } else if let chapterFrame = frame as? ChapFrame {
            self = .chapter(ID3Chapter(
                elementID: chapterFrame.elementID,
                startTimeMilliseconds: UInt32(clamping: Int(chapterFrame.startTime)),
                endTimeMilliseconds: UInt32(clamping: Int(chapterFrame.endTime)),
                startOffset: UInt32(clamping: chapterFrame.startOffset),
                endOffset: UInt32(clamping: chapterFrame.endOffset),
                subframes: chapterFrame.frames.map(ID3MutableFrame.init(frame:))
            ))
        } else if let tocFrame = frame as? CTOCFrame {
            self = .tableOfContents(ID3TableOfContents(
                elementID: tocFrame.elementID,
                isTopLevel: tocFrame.isTopLevel,
                isOrdered: tocFrame.isOrdered,
                childElementIDs: tocFrame.childElementIDs,
                subframes: tocFrame.frames.map(ID3MutableFrame.init(frame:))
            ))
        } else {
            self = .raw(id: frame.frameID, flags: frame.flags, body: frame.rawBody)
        }
    }
}

enum ID3FrameSerializer {
    static func serialize(frames: [ID3MutableFrame], version: Int) throws -> Data {
        var data = Data()
        for frame in frames {
            data.append(try serialize(frame: frame, version: version))
        }
        return data
    }

    private static func serialize(frame: ID3MutableFrame, version: Int) throws -> Data {
        let body: Data
        let flags: FrameFlags

        switch frame {
        case .text(let id, let values):
            try validateFrameIdentifier(id)
            body = textBody(values: values, version: version)
            flags = FrameFlags()
        case .url(let id, let url, let description):
            try validateFrameIdentifier(id)
            body = urlBody(id: id, url: url, description: description, version: version)
            flags = FrameFlags()
        case .picture(let picture):
            body = pictureBody(picture, version: version)
            flags = FrameFlags()
        case .chapter(let chapter):
            body = try chapterBody(chapter, version: version)
            flags = FrameFlags()
        case .tableOfContents(let tableOfContents):
            body = try tableOfContentsBody(tableOfContents, version: version)
            flags = FrameFlags()
        case .raw(let id, let rawFlags, let rawBody):
            try validateFrameIdentifier(id)
            body = rawBody
            flags = rawFlags
        }

        return try frameHeader(id: frame.id, bodySize: body.count, flags: flags, version: version) + body
    }

    private static func frameHeader(id: String, bodySize: Int, flags: FrameFlags, version: Int) throws -> Data {
        try validateFrameIdentifier(id)

        var data = Data(id.utf8)
        if version == 4 {
            data.append(contentsOf: synchsafeBytes(bodySize))
        } else {
            data.append(contentsOf: uint32Bytes(bodySize))
        }

        let flagBytes = frameFlagBytes(flags, version: version)
        data.append(flagBytes.0)
        data.append(flagBytes.1)
        return data
    }

    private static func validateFrameIdentifier(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard id.count == 4, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ID3TagDocumentError.invalidFrameIdentifier(id)
        }
    }

    private static func frameFlagBytes(_ flags: FrameFlags, version: Int) -> (UInt8, UInt8) {
        var byte1: UInt8 = 0
        var byte2: UInt8 = 0

        if version == 3 {
            if flags.isTagAlterPreservation { byte1 |= 0x80 }
            if flags.isFileAlterPreservation { byte1 |= 0x40 }
            if flags.isReadOnly { byte1 |= 0x20 }
            if flags.isCompressed { byte2 |= 0x80 }
            if flags.isEncrypted { byte2 |= 0x40 }
            if flags.isGroupingIdentity { byte2 |= 0x20 }
        } else {
            if flags.isTagAlterPreservation { byte1 |= 0x40 }
            if flags.isFileAlterPreservation { byte1 |= 0x20 }
            if flags.isReadOnly { byte1 |= 0x10 }
            if flags.isGroupingIdentity { byte2 |= 0x40 }
            if flags.isCompressed { byte2 |= 0x08 }
            if flags.isEncrypted { byte2 |= 0x04 }
            if flags.isUnsynchronized { byte2 |= 0x02 }
            if flags.hasDataLengthIndicator { byte2 |= 0x01 }
        }

        return (byte1, byte2)
    }

    private static func textBody(values: [String], version: Int) -> Data {
        let encoding = textEncodingByte(for: version)
        var data = Data([encoding])
        let separator = textTerminator(for: encoding)

        for (index, value) in values.enumerated() {
            data.append(encodedString(value, encoding: encoding))
            if index < values.count - 1 {
                data.append(separator)
            }
        }

        return data
    }

    private static func urlBody(id: String, url: String, description: String?, version: Int) -> Data {
        guard id == "WXXX" else {
            return Data(url.utf8)
        }

        let encoding = textEncodingByte(for: version)
        var data = Data([encoding])
        data.append(encodedString(description ?? "", encoding: encoding))
        data.append(textTerminator(for: encoding))
        data.append(Data(url.utf8))
        return data
    }

    private static func pictureBody(_ picture: ID3Picture, version: Int) -> Data {
        let encoding = textEncodingByte(for: version)
        var data = Data([encoding])
        data.append(Data(picture.mimeType.utf8))
        data.append(0x00)
        data.append(picture.type.rawValue)
        data.append(encodedString(picture.description, encoding: encoding))
        data.append(textTerminator(for: encoding))
        data.append(picture.data)
        return data
    }

    private static func chapterBody(_ chapter: ID3Chapter, version: Int) throws -> Data {
        var data = latin1TerminatedString(chapter.elementID)
        data.append(contentsOf: uint32Bytes(Int(chapter.startTimeMilliseconds)))
        data.append(contentsOf: uint32Bytes(Int(chapter.endTimeMilliseconds)))
        data.append(contentsOf: uint32Bytes(Int(chapter.startOffset)))
        data.append(contentsOf: uint32Bytes(Int(chapter.endOffset)))
        data.append(try serialize(frames: chapter.subframes, version: version))
        return data
    }

    private static func tableOfContentsBody(_ toc: ID3TableOfContents, version: Int) throws -> Data {
        guard toc.childElementIDs.count <= 255 else {
            throw ID3TagDocumentError.tooManyTableOfContentsChildren(toc.childElementIDs.count)
        }

        var data = latin1TerminatedString(toc.elementID)
        var flags: UInt8 = 0
        if toc.isTopLevel { flags |= 0x02 }
        if toc.isOrdered { flags |= 0x01 }
        data.append(flags)
        data.append(UInt8(toc.childElementIDs.count))
        for child in toc.childElementIDs {
            data.append(latin1TerminatedString(child))
        }
        data.append(try serialize(frames: toc.subframes, version: version))
        return data
    }

    private static func textEncodingByte(for version: Int) -> UInt8 {
        version == 3 ? 0x01 : 0x03
    }

    private static func encodedString(_ value: String, encoding: UInt8) -> Data {
        switch encoding {
        case 0x01:
            return Data([0xFF, 0xFE]) + (value.data(using: .utf16LittleEndian) ?? Data())
        case 0x02:
            return value.data(using: .utf16BigEndian) ?? Data()
        case 0x03:
            return Data(value.utf8)
        default:
            return value.data(using: .isoLatin1) ?? Data(value.utf8)
        }
    }

    private static func textTerminator(for encoding: UInt8) -> Data {
        switch encoding {
        case 0x01, 0x02:
            return Data([0x00, 0x00])
        default:
            return Data([0x00])
        }
    }

    private static func latin1TerminatedString(_ value: String) -> Data {
        var data = value.data(using: .isoLatin1) ?? Data(value.utf8)
        data.append(0x00)
        return data
    }

    static func synchsafeBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    private static func uint32Bytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}
