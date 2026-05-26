import Compression
import Foundation

let id3v22FrameHeaderSize = 6
let id3v2FrameHeaderSize = 10

private let v22ToV23FrameMap: [String: String] = [
    "BUF": "RBUF",
    "CNT": "PCNT",
    "COM": "COMM",
    "CRA": "AENC",
    "EQU": "EQUA",
    "ETC": "ETCO",
    "GEO": "GEOB",
    "IPL": "IPLS",
    "LNK": "LINK",
    "MCI": "MCDI",
    "MLL": "MLLT",
    "PIC": "APIC",
    "POP": "POPM",
    "REV": "RVRB",
    "RVA": "RVAD",
    "SLT": "SYLT",
    "STC": "SYTC",
    "TAL": "TALB",
    "TBP": "TBPM",
    "TCM": "TCOM",
    "TCO": "TCON",
    "TCR": "TCOP",
    "TDA": "TDAT",
    "TDY": "TDLY",
    "TEN": "TENC",
    "TFT": "TFLT",
    "TIM": "TIME",
    "TKE": "TKEY",
    "TLA": "TLAN",
    "TLE": "TLEN",
    "TMT": "TMED",
    "TOA": "TOPE",
    "TOF": "TOFN",
    "TOL": "TOLY",
    "TOR": "TORY",
    "TOT": "TOAL",
    "TP1": "TPE1",
    "TP2": "TPE2",
    "TP3": "TPE3",
    "TP4": "TPE4",
    "TPA": "TPOS",
    "TPB": "TPUB",
    "TRC": "TSRC",
    "TRD": "TRDA",
    "TRK": "TRCK",
    "TSI": "TSIZ",
    "TSS": "TSSE",
    "TT1": "TIT1",
    "TT2": "TIT2",
    "TT3": "TIT3",
    "TXT": "TEXT",
    "TXX": "TXXX",
    "TYE": "TYER",
    "UFI": "UFID",
    "ULT": "USLT",
    "WAF": "WOAF",
    "WAR": "WOAR",
    "WAS": "WOAS",
    "WCM": "WCOM",
    "WCP": "WCOP",
    "WPB": "WPUB",
    "WXX": "WXXX"
]

private let creditsFrameIDs: Set<String> = ["TIPL", "TMCL", "IPLS"]
private let relativeVolumeFrameIDs: Set<String> = ["RVA2", "RVAD"]
private let equalisationFrameIDs: Set<String> = ["EQU2", "EQUA"]

public struct FrameFlags: Sendable, Equatable {
    public var isTagAlterPreservation = false
    public var isFileAlterPreservation = false
    public var isReadOnly = false

    public var isGroupingIdentity = false
    public var isCompressed = false
    public var isEncrypted = false
    public var isUnsynchronized = false
    public var hasDataLengthIndicator = false

    public var groupIdentifier: UInt8?
    public var encryptionMethod: UInt8?
    public var dataLengthIndicator: Int?
    public var decompressedSize: Int?

    func createDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "tagAlterPreservation": isTagAlterPreservation,
            "fileAlterPreservation": isFileAlterPreservation,
            "readOnly": isReadOnly,
            "groupingIdentity": isGroupingIdentity,
            "compressed": isCompressed,
            "encrypted": isEncrypted,
            "unsynchronized": isUnsynchronized,
            "dataLengthIndicator": hasDataLengthIndicator
        ]

        if let groupIdentifier {
            dict["groupIdentifier"] = Int(groupIdentifier)
        }
        if let encryptionMethod {
            dict["encryptionMethod"] = Int(encryptionMethod)
        }
        if let dataLengthIndicator {
            dict["dataLengthIndicatorValue"] = dataLengthIndicator
        }
        if let decompressedSize {
            dict["decompressedSize"] = decompressedSize
        }

        return dict
    }
}

struct ID3FrameHeader {
    var frameID: String
    var originalFrameID: String
    var size: Int
    var headerSize: Int
    var flags: FrameFlags
}

struct FrameParsingContext {
    let version: Int
    let tagUnsynchronization: Bool
}

private struct StrippedFrameBody {
    let payloadBody: Data
    let readableBody: Data?
    let flags: FrameFlags
}

private struct EncodedStringResult {
    let value: String?
    let nextIndex: Int
}

private struct ID3StringCodec {
    static func stringEncoding(for encodingByte: UInt8) -> String.Encoding {
        switch encodingByte {
        case 0x00:
            return .isoLatin1
        case 0x01:
            return .utf16
        case 0x02:
            return .utf16BigEndian
        case 0x03:
            return .utf8
        default:
            return .isoLatin1
        }
    }

    static func terminatorLength(for encodingByte: UInt8) -> Int {
        switch encodingByte {
        case 0x01, 0x02:
            return 2
        default:
            return 1
        }
    }

    static func latin1String(from data: Data) -> String? {
        String(data: data, encoding: .isoLatin1)
    }

    static func readLatin1String(from data: Data, startingAt index: Int, terminated: Bool) -> EncodedStringResult {
        let normalized = Data(data)

        guard index <= normalized.count else {
            return EncodedStringResult(value: nil, nextIndex: normalized.count)
        }

        if !terminated {
            let value = latin1String(from: normalized.subdata(in: index..<normalized.count))
            return EncodedStringResult(value: value, nextIndex: normalized.count)
        }

        let endIndex = normalized[index..<normalized.count].firstIndex(of: 0) ?? normalized.count
        let value = latin1String(from: normalized.subdata(in: index..<endIndex))
        let nextIndex = min(endIndex + 1, normalized.count)
        return EncodedStringResult(value: value, nextIndex: nextIndex)
    }

    static func readEncodedString(from data: Data, startingAt index: Int, encodingByte: UInt8, byteOrderHint: inout String.Encoding?) -> EncodedStringResult {
        let normalized = Data(data)

        guard index <= normalized.count else {
            return EncodedStringResult(value: nil, nextIndex: normalized.count)
        }

        let terminatorLength = terminatorLength(for: encodingByte)
        var endIndex = normalized.count

        if terminatorLength == 1 {
            endIndex = normalized[index..<normalized.count].firstIndex(of: 0) ?? normalized.count
        } else {
            var searchIndex = index
            while searchIndex + 1 < normalized.count {
                if normalized[searchIndex] == 0 && normalized[searchIndex + 1] == 0 {
                    endIndex = searchIndex
                    break
                }
                searchIndex += 2
            }
        }

        let stringData = normalized.subdata(in: index..<endIndex)
        let value = decodeString(data: stringData, encodingByte: encodingByte, byteOrderHint: &byteOrderHint)
        let nextIndex = min(endIndex + terminatorLength, normalized.count)
        return EncodedStringResult(value: value, nextIndex: nextIndex)
    }

    static func decodeStrings(from data: Data, encodingByte: UInt8) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        var values: [String] = []
        var index = 0
        var byteOrderHint: String.Encoding?

        while index < data.count {
            let result = readEncodedString(from: data, startingAt: index, encodingByte: encodingByte, byteOrderHint: &byteOrderHint)
            if let value = result.value {
                values.append(value)
            }
            if result.nextIndex <= index || result.nextIndex >= data.count {
                break
            }
            index = result.nextIndex
        }

        if values.isEmpty {
            let fallback = decodeString(data: data, encodingByte: encodingByte, byteOrderHint: &byteOrderHint)
            if let fallback, !fallback.isEmpty {
                values.append(fallback)
            }
        }

        return values
    }

    static func decodeString(data: Data, encodingByte: UInt8, byteOrderHint: inout String.Encoding?) -> String? {
        switch encodingByte {
        case 0x00:
            return String(data: data, encoding: .isoLatin1)
        case 0x01:
            if data.count >= 2 {
                if data[0] == 0xFF && data[1] == 0xFE {
                    byteOrderHint = .utf16LittleEndian
                    return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
                        ?? String(data: data, encoding: .utf16)
                }
                if data[0] == 0xFE && data[1] == 0xFF {
                    byteOrderHint = .utf16BigEndian
                    return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
                        ?? String(data: data, encoding: .utf16)
                }
            }

            if let byteOrderHint {
                return String(data: data, encoding: byteOrderHint)
            }

            return String(data: data, encoding: .utf16)
        case 0x02:
            return String(data: data, encoding: .utf16BigEndian)
        case 0x03:
            return String(data: data, encoding: .utf8)
        default:
            return String(data: data, encoding: .isoLatin1)
        }
    }
}

public class Frame: Decodable, @unchecked Sendable {
    public var frameID: String = ""
    public var originalFrameID: String = ""
    public var size: Int = 0
    public var flags = FrameFlags()
    public var rawBody = Data()

    init(header: ID3FrameHeader, rawBody: Data) {
        frameID = header.frameID
        originalFrameID = header.originalFrameID
        size = header.size
        flags = header.flags
        self.rawBody = rawBody
    }

    func payloadValue() -> Any {
        var dict: [String: Any] = [
            "rawData": rawBody
        ]

        let flagDict = flags.createDictionary()
        if !flagDict.isEmpty {
            dict["flags"] = flagDict
        }
        if originalFrameID != frameID {
            dict["originalFrameID"] = originalFrameID
        }

        return dict
    }

    func createDictionary() -> [String: Any] {
        [frameID: payloadValue()]
    }

    required public init(from decoder: Decoder) throws {}

    class func createInstance(header: ID3FrameHeader, rawBody: Data, parsedBody: Data, context: FrameParsingContext) -> Frame {
        if header.flags.isEncrypted {
            return StructuredFrame(header: header, rawBody: rawBody, details: [
                "rawData": parsedBody,
                "flags": header.flags.createDictionary()
            ])
        }

        switch header.frameID {
        case "CHAP":
            return ChapFrame(header: header, rawBody: rawBody, parsedBody: parsedBody, context: context)
        case "CTOC":
            return CTOCFrame(header: header, rawBody: rawBody, parsedBody: parsedBody, context: context)
        case "APIC":
            return PictureFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "TXXX":
            return makeUserTextFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "WXXX":
            return LinkFrame(header: header, rawBody: rawBody, parsedBody: parsedBody, userDefined: true)
        case "COMM", "USLT":
            return makeLanguageTextFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "SYLT":
            return makeSynchronisedLyricsFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "GEOB":
            return makeGeneralObjectFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "UFID":
            return makeUniqueFileIdentifierFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "PRIV":
            return makePrivateFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "PCNT":
            return makePlayCounterFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "POPM":
            return makePopularimeterFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "RBUF":
            return makeRecommendedBufferFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "AENC":
            return makeAudioEncryptionFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "LINK":
            return makeLinkedInformationFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "POSS":
            return makePositionSynchronisationFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "USER":
            return makeTermsOfUseFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "OWNE":
            return makeOwnershipFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "COMR":
            return makeCommercialFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "ENCR":
            return makeEncryptionMethodRegistrationFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "GRID":
            return makeGroupIdentificationFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "SIGN":
            return makeSignatureFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "SEEK":
            return makeSeekFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "ASPI":
            return makeAudioSeekPointIndexFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "MCDI":
            return StructuredFrame(header: header, rawBody: rawBody, details: ["Data": parsedBody])
        case "ETCO":
            return makeEventTimingFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "MLLT":
            return makeLocationLookupTableFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "SYTC":
            return makeSynchronisedTempoCodesFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        case "RVRB":
            return makeReverbFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
        default:
            if creditsFrameIDs.contains(header.frameID) {
                return CreditsFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
            }
            if relativeVolumeFrameIDs.contains(header.frameID) {
                return makeRelativeVolumeFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
            }
            if equalisationFrameIDs.contains(header.frameID) {
                return makeEqualisationFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
            }
            if header.frameID.hasPrefix("T") {
                return TextFrame(header: header, rawBody: rawBody, parsedBody: parsedBody)
            }
            if header.frameID.hasPrefix("W") {
                return LinkFrame(header: header, rawBody: rawBody, parsedBody: parsedBody, userDefined: false)
            }

            return StructuredFrame(header: header, rawBody: rawBody, details: [
                "rawData": parsedBody,
                "flags": header.flags.createDictionary()
            ])
        }
    }
}

public class StructuredFrame: Frame, @unchecked Sendable {
    public var details: [String: Any] = [:]

    init(header: ID3FrameHeader, rawBody: Data, details: [String: Any]) {
        self.details = details
        super.init(header: header, rawBody: rawBody)
    }

    override func payloadValue() -> Any {
        details
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class TextFrame: Frame, @unchecked Sendable {
    public var textEncoding: String.Encoding = .isoLatin1
    public var values: [String] = []
    public var information: String? {
        values.first
    }

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) {
        super.init(header: header, rawBody: rawBody)

        guard let encodingByte = parsedBody.first else {
            return
        }

        textEncoding = ID3StringCodec.stringEncoding(for: encodingByte)
        values = ID3StringCodec.decodeStrings(from: Data(parsedBody.dropFirst()), encodingByte: encodingByte)
    }

    override func payloadValue() -> Any {
        if values.count <= 1 {
            return values.first ?? ""
        }
        return values
    }

    override func createDictionary() -> [String: Any] {
        var dict = super.createDictionary()
        if frameID == "TIT1" {
            dict["Title"] = payloadValue()
        }
        return dict
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class CreditsFrame: Frame, @unchecked Sendable {
    public var textEncoding: String.Encoding = .isoLatin1
    public var pairs: [[String: String]] = []

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) {
        super.init(header: header, rawBody: rawBody)

        guard let encodingByte = parsedBody.first else {
            return
        }

        textEncoding = ID3StringCodec.stringEncoding(for: encodingByte)
        let values = ID3StringCodec.decodeStrings(from: Data(parsedBody.dropFirst()), encodingByte: encodingByte)

        var index = 0
        while index + 1 < values.count {
            pairs.append([
                "role": values[index],
                "name": values[index + 1]
            ])
            index += 2
        }

        if index < values.count {
            pairs.append([
                "role": values[index],
                "name": ""
            ])
        }
    }

    override func payloadValue() -> Any {
        pairs
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class LinkFrame: Frame, @unchecked Sendable {
    public var textEncoding: String.Encoding = .isoLatin1
    public var descriptionText: String?
    public var urlString: String?
    public var userDefined = false

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data, userDefined: Bool) {
        self.userDefined = userDefined
        super.init(header: header, rawBody: rawBody)

        if userDefined {
            guard let encodingByte = parsedBody.first else {
                return
            }

            textEncoding = ID3StringCodec.stringEncoding(for: encodingByte)
            var byteOrderHint: String.Encoding?
            let description = ID3StringCodec.readEncodedString(
                from: parsedBody,
                startingAt: 1,
                encodingByte: encodingByte,
                byteOrderHint: &byteOrderHint
            )
            descriptionText = description.value
            urlString = String(
                data: parsedBody.subdata(in: description.nextIndex..<parsedBody.count),
                encoding: .isoLatin1
            )
        } else {
            urlString = String(data: parsedBody, encoding: .isoLatin1)
        }
    }

    override func payloadValue() -> Any {
        if userDefined {
            return [
                "Description": descriptionText as Any,
                "Url": urlString as Any
            ]
        }
        return urlString ?? ""
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class PictureFrame: Frame, @unchecked Sendable {
    public var mimeType: String?
    public var type: PictureType?
    public var descriptionText: String?
    public var image: Data?

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) {
        super.init(header: header, rawBody: rawBody)

        guard let encodingByte = parsedBody.first else {
            return
        }

        var currentIndex = 1

        if header.originalFrameID == "PIC" {
            guard parsedBody.count >= currentIndex + 4 else {
                return
            }

            let formatData = parsedBody.subdata(in: currentIndex..<(currentIndex + 3))
            let format = String(data: formatData, encoding: .isoLatin1)?.lowercased() ?? ""
            mimeType = pictureMimeType(fromLegacyFormat: format)
            currentIndex += 3
        } else {
            let mimeResult = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: currentIndex, terminated: true)
            mimeType = mimeResult.value
            currentIndex = mimeResult.nextIndex
        }

        guard currentIndex < parsedBody.count else {
            return
        }

        type = PictureType(rawValue: parsedBody[currentIndex])
        currentIndex += 1

        var byteOrderHint: String.Encoding?
        let description = ID3StringCodec.readEncodedString(
            from: parsedBody,
            startingAt: currentIndex,
            encodingByte: encodingByte,
            byteOrderHint: &byteOrderHint
        )
        descriptionText = description.value
        currentIndex = description.nextIndex

        if currentIndex < parsedBody.count {
            image = parsedBody.subdata(in: currentIndex..<parsedBody.count)
        }
    }

    override func payloadValue() -> Any {
        [
            "Description": descriptionText as Any,
            "Type": type?.description ?? "",
            "MIME type": mimeType ?? "",
            "Data": image as Any
        ]
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class ChapFrame: Frame, @unchecked Sendable {
    public var elementID: String = ""
    public var startTime: Double = 0
    public var endTime: Double = 0
    public var startOffset: Int = 0
    public var endOffset: Int = 0
    public var frames: [Frame] = []

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data, context: FrameParsingContext) {
        super.init(header: header, rawBody: rawBody)

        let elementResult = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
        elementID = elementResult.value ?? ""
        var currentIndex = elementResult.nextIndex

        guard currentIndex + 16 <= parsedBody.count else {
            return
        }

        startTime = Double(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4
        endTime = Double(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4
        startOffset = Int(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4
        endOffset = Int(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4

        if currentIndex < parsedBody.count {
            let subframeData = parsedBody.subdata(in: currentIndex..<parsedBody.count)
            frames = ID3FrameParser.parseFrames(
                in: subframeData,
                version: context.version,
                tagUnsynchronization: false
            )
        }
    }

    override func createDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "timeScale": "seconds",
            "startTime": startTime / 1000,
            "endTime": endTime / 1000
        ]

        if startOffset != Int(UInt32.max) {
            dict["startOffset"] = startOffset
        }
        if endOffset != Int(UInt32.max) {
            dict["endOffset"] = endOffset
        }

        for frame in frames {
            mergeFrameDictionary(into: &dict, frameDictionary: frame.createDictionary())
        }

        return dict
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

public class CTOCFrame: Frame, @unchecked Sendable {
    public var elementID: String = ""
    public var isTopLevel = false
    public var isOrdered = false
    public var childElementIDs: [String] = []
    public var frames: [Frame] = []

    init(header: ID3FrameHeader, rawBody: Data, parsedBody: Data, context: FrameParsingContext) {
        super.init(header: header, rawBody: rawBody)

        let elementResult = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
        elementID = elementResult.value ?? ""
        var currentIndex = elementResult.nextIndex

        guard currentIndex + 2 <= parsedBody.count else {
            return
        }

        let tocFlags = parsedBody[currentIndex]
        isTopLevel = (tocFlags & 0x02) != 0
        isOrdered = (tocFlags & 0x01) != 0
        currentIndex += 1

        let entryCount = Int(parsedBody[currentIndex])
        currentIndex += 1

        for _ in 0..<entryCount {
            let childResult = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: currentIndex, terminated: true)
            if let child = childResult.value {
                childElementIDs.append(child)
            }
            currentIndex = childResult.nextIndex
            if currentIndex >= parsedBody.count {
                break
            }
        }

        if currentIndex < parsedBody.count {
            let subframeData = parsedBody.subdata(in: currentIndex..<parsedBody.count)
            frames = ID3FrameParser.parseFrames(
                in: subframeData,
                version: context.version,
                tagUnsynchronization: false
            )
        }
    }

    override func createDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": elementID,
            "topLevel": isTopLevel,
            "ordered": isOrdered,
            "children": childElementIDs
        ]

        for frame in frames {
            mergeFrameDictionary(into: &dict, frameDictionary: frame.createDictionary())
        }

        return dict
    }

    required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

enum ID3FrameParser {
    static func parseFrames(in data: Data, version: Int, tagUnsynchronization: Bool) -> [Frame] {
        var frames: [Frame] = []
        var currentIndex = 0
        let minimumHeaderSize = version == 2 ? id3v22FrameHeaderSize : id3v2FrameHeaderSize

        while currentIndex + minimumHeaderSize <= data.count {
            guard let header = readHeader(in: data, at: currentIndex, version: version) else {
                break
            }

            if header.frameID.isEmpty || header.size <= 0 {
                break
            }

            let bodyStart = currentIndex + header.headerSize
            let bodyEnd = bodyStart + header.size
            guard bodyEnd <= data.count else {
                break
            }

            let rawBody = data.subdata(in: bodyStart..<bodyEnd)
            var processedBody = rawBody

            if tagUnsynchronization || header.flags.isUnsynchronized {
                processedBody = processedBody.deunsynchronized()
            }

            let stripped = stripAdditionalHeaderData(from: processedBody, version: version, flags: header.flags)
            var effectiveHeader = header
            effectiveHeader.flags = stripped.flags

            let readableBody = stripped.readableBody ?? stripped.payloadBody
            let frame = Frame.createInstance(
                header: effectiveHeader,
                rawBody: rawBody,
                parsedBody: readableBody,
                context: FrameParsingContext(version: version, tagUnsynchronization: false)
            )
            frames.append(frame)

            currentIndex = bodyEnd
        }

        return frames
    }

    private static func readHeader(in data: Data, at index: Int, version: Int) -> ID3FrameHeader? {
        if version == 2 {
            guard index + id3v22FrameHeaderSize <= data.count else {
                return nil
            }

            let rawID = String(data: data.subdata(in: index..<(index + 3)), encoding: .isoLatin1) ?? ""
            if rawID == "\0\0\0" {
                return nil
            }

            let canonicalID = v22ToV23FrameMap[rawID] ?? rawID
            let size = data.readUInt24BigEndian(at: index + 3)

            return ID3FrameHeader(
                frameID: canonicalID,
                originalFrameID: rawID,
                size: size,
                headerSize: id3v22FrameHeaderSize,
                flags: FrameFlags()
            )
        }

        guard index + id3v2FrameHeaderSize <= data.count else {
            return nil
        }

        let rawID = String(data: data.subdata(in: index..<(index + 4)), encoding: .isoLatin1) ?? ""
        if rawID == "\0\0\0\0" {
            return nil
        }

        let size: Int
        if version == 4 {
            size = data.readSynchsafeInt(at: index + 4)
        } else {
            size = Int(data.readUInt32BigEndian(at: index + 4))
        }

        let flagByte1 = data[index + 8]
        let flagByte2 = data[index + 9]
        var flags = FrameFlags()

        if version == 3 {
            flags.isTagAlterPreservation = (flagByte1 & 0x80) != 0
            flags.isFileAlterPreservation = (flagByte1 & 0x40) != 0
            flags.isReadOnly = (flagByte1 & 0x20) != 0

            flags.isCompressed = (flagByte2 & 0x80) != 0
            flags.isEncrypted = (flagByte2 & 0x40) != 0
            flags.isGroupingIdentity = (flagByte2 & 0x20) != 0
        } else {
            flags.isTagAlterPreservation = (flagByte1 & 0x40) != 0
            flags.isFileAlterPreservation = (flagByte1 & 0x20) != 0
            flags.isReadOnly = (flagByte1 & 0x10) != 0

            flags.isGroupingIdentity = (flagByte2 & 0x40) != 0
            flags.isCompressed = (flagByte2 & 0x08) != 0
            flags.isEncrypted = (flagByte2 & 0x04) != 0
            flags.isUnsynchronized = (flagByte2 & 0x02) != 0
            flags.hasDataLengthIndicator = (flagByte2 & 0x01) != 0
        }

        return ID3FrameHeader(
            frameID: rawID,
            originalFrameID: rawID,
            size: size,
            headerSize: id3v2FrameHeaderSize,
            flags: flags
        )
    }

    private static func stripAdditionalHeaderData(from body: Data, version: Int, flags: FrameFlags) -> StrippedFrameBody {
        var updatedFlags = flags
        var currentIndex = 0
        let workingBody = body

        if version == 3 {
            if updatedFlags.isCompressed, currentIndex + 4 <= workingBody.count {
                updatedFlags.decompressedSize = Int(workingBody.readUInt32BigEndian(at: currentIndex))
                currentIndex += 4
            }
            if updatedFlags.isEncrypted, currentIndex < workingBody.count {
                updatedFlags.encryptionMethod = workingBody[currentIndex]
                currentIndex += 1
            }
            if updatedFlags.isGroupingIdentity, currentIndex < workingBody.count {
                updatedFlags.groupIdentifier = workingBody[currentIndex]
                currentIndex += 1
            }
        } else if version == 4 {
            if updatedFlags.isGroupingIdentity, currentIndex < workingBody.count {
                updatedFlags.groupIdentifier = workingBody[currentIndex]
                currentIndex += 1
            }
            if updatedFlags.isEncrypted, currentIndex < workingBody.count {
                updatedFlags.encryptionMethod = workingBody[currentIndex]
                currentIndex += 1
            }
            if updatedFlags.hasDataLengthIndicator, currentIndex + 4 <= workingBody.count {
                updatedFlags.dataLengthIndicator = workingBody.readSynchsafeInt(at: currentIndex)
                currentIndex += 4
            }
        }

        let payloadBody: Data
        if currentIndex < workingBody.count {
            payloadBody = workingBody.subdata(in: currentIndex..<workingBody.count)
        } else {
            payloadBody = Data()
        }

        let readableBody: Data?
        if updatedFlags.isEncrypted {
            readableBody = nil
        } else if updatedFlags.isCompressed {
            let expectedSize = updatedFlags.dataLengthIndicator ?? updatedFlags.decompressedSize
            readableBody = payloadBody.zlibDecompressed(expectedSize: expectedSize)
        } else {
            readableBody = payloadBody
        }

        return StrippedFrameBody(payloadBody: payloadBody, readableBody: readableBody, flags: updatedFlags)
    }
}

func mergeFrameDictionary(into target: inout [String: Any], frameDictionary: [String: Any]) {
    for (key, value) in frameDictionary {
        if let existing = target[key] {
            target[key] = mergeFrameValues(existing: existing, incoming: value)
        } else {
            target[key] = value
        }
    }
}

private func mergeFrameValues(existing: Any, incoming: Any) -> Any {
    if var existingArray = existing as? [Any] {
        existingArray.append(incoming)
        return existingArray
    }

    return [existing, incoming]
}

private func pictureMimeType(fromLegacyFormat format: String) -> String {
    switch format.uppercased() {
    case "PNG":
        return "image/png"
    case "JPG":
        return "image/jpeg"
    default:
        return "image/\(format)"
    }
}

private func makeUserTextFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let encodingByte = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var byteOrderHint: String.Encoding?
    let description = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: 1,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )
    let values = ID3StringCodec.decodeStrings(
        from: parsedBody.subdata(in: description.nextIndex..<parsedBody.count),
        encodingByte: encodingByte
    )

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Description": description.value as Any,
        "Value": values.count <= 1 ? (values.first ?? "") : values
    ])
}

private func makeLanguageTextFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 4 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let encodingByte = parsedBody[0]
    let language = String(data: parsedBody.subdata(in: 1..<4), encoding: .isoLatin1) ?? "XXX"
    var byteOrderHint: String.Encoding?
    let description = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: 4,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )
    let textData = parsedBody.subdata(in: description.nextIndex..<parsedBody.count)
    let text = ID3StringCodec.decodeString(data: textData, encodingByte: encodingByte, byteOrderHint: &byteOrderHint) ?? ""

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Language": language,
        "Description": description.value as Any,
        header.frameID == "COMM" ? "Comment" : "Lyrics": text
    ])
}

private func makeSynchronisedLyricsFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 6 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let encodingByte = parsedBody[0]
    let language = String(data: parsedBody.subdata(in: 1..<4), encoding: .isoLatin1) ?? "XXX"
    let timestampFormat = Int(parsedBody[4])
    let contentType = Int(parsedBody[5])
    var byteOrderHint: String.Encoding?
    let description = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: 6,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )

    var items: [[String: Any]] = []
    var currentIndex = description.nextIndex

    while currentIndex < parsedBody.count {
        let textPart = ID3StringCodec.readEncodedString(
            from: parsedBody,
            startingAt: currentIndex,
            encodingByte: encodingByte,
            byteOrderHint: &byteOrderHint
        )
        currentIndex = textPart.nextIndex
        guard currentIndex + 4 <= parsedBody.count else {
            break
        }

        let timestamp = Int(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4
        items.append([
            "text": textPart.value as Any,
            "timestamp": timestamp
        ])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Language": language,
        "TimestampFormat": timestampFormat,
        "ContentType": contentType,
        "Description": description.value as Any,
        "Items": items
    ])
}

private func makeGeneralObjectFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let encodingByte = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var byteOrderHint: String.Encoding?
    let mimeType = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 1, terminated: true)
    let filename = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: mimeType.nextIndex,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )
    let description = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: filename.nextIndex,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )

    let objectData = description.nextIndex <= parsedBody.count
        ? parsedBody.subdata(in: description.nextIndex..<parsedBody.count)
        : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "MIME type": mimeType.value as Any,
        "Filename": filename.value as Any,
        "Description": description.value as Any,
        "Data": objectData
    ])
}

private func makeUniqueFileIdentifierFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let owner = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    let identifier = owner.nextIndex <= parsedBody.count
        ? parsedBody.subdata(in: owner.nextIndex..<parsedBody.count)
        : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "OwnerIdentifier": owner.value as Any,
        "Identifier": identifier
    ])
}

private func makePrivateFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let owner = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    let privateData = owner.nextIndex <= parsedBody.count
        ? parsedBody.subdata(in: owner.nextIndex..<parsedBody.count)
        : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "OwnerIdentifier": owner.value as Any,
        "Data": privateData
    ])
}

private func makePlayCounterFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    StructuredFrame(header: header, rawBody: rawBody, details: [
        "Count": parsedBody.readVariableLengthInteger()
    ])
}

private func makePopularimeterFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let email = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    let rating = email.nextIndex < parsedBody.count ? Int(parsedBody[email.nextIndex]) : 0
    let counterDataStart = min(email.nextIndex + 1, parsedBody.count)
    let counter = parsedBody.subdata(in: counterDataStart..<parsedBody.count).readVariableLengthInteger()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Email": email.value as Any,
        "Rating": rating,
        "Count": counter
    ])
}

private func makeRecommendedBufferFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 4 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var details: [String: Any] = [
        "BufferSize": parsedBody.readUInt24BigEndian(at: 0),
        "EmbeddedInfo": (parsedBody[3] & 0x01) != 0
    ]
    if parsedBody.count >= 8 {
        details["OffsetToNextTag"] = Int(parsedBody.readUInt32BigEndian(at: 4))
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: details)
}

private func makeAudioEncryptionFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let owner = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    guard owner.nextIndex + 4 <= parsedBody.count else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "OwnerIdentifier": owner.value as Any
        ])
    }

    let previewStart = Int(parsedBody.readUInt16BigEndian(at: owner.nextIndex))
    let previewLength = Int(parsedBody.readUInt16BigEndian(at: owner.nextIndex + 2))
    let dataStart = owner.nextIndex + 4
    let encryptionInfo = parsedBody.subdata(in: dataStart..<parsedBody.count)

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "OwnerIdentifier": owner.value as Any,
        "PreviewStart": previewStart,
        "PreviewLength": previewLength,
        "EncryptionInfo": encryptionInfo
    ])
}

private func makeLinkedInformationFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 4 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let linkedFrameID = String(data: parsedBody.subdata(in: 0..<4), encoding: .isoLatin1) ?? ""
    let url = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 4, terminated: true)
    let additionalIDData = url.nextIndex <= parsedBody.count
        ? parsedBody.subdata(in: url.nextIndex..<parsedBody.count)
        : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "LinkedFrameID": linkedFrameID,
        "URL": url.value as Any,
        "AdditionalIDData": additionalIDData
    ])
}

private func makePositionSynchronisationFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 5 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "TimestampFormat": Int(parsedBody[0]),
        "Position": Int(parsedBody.readUInt32BigEndian(at: 1))
    ])
}

private func makeTermsOfUseFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 4 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let encodingByte = parsedBody[0]
    let language = String(data: parsedBody.subdata(in: 1..<4), encoding: .isoLatin1) ?? "XXX"
    var byteOrderHint: String.Encoding?
    let text = ID3StringCodec.decodeString(
        data: parsedBody.subdata(in: 4..<parsedBody.count),
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    ) ?? ""

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Language": language,
        "Terms": text
    ])
}

private func makeOwnershipFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let encodingByte = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let price = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 1, terminated: true)
    guard price.nextIndex + 8 <= parsedBody.count else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "Price": price.value as Any
        ])
    }

    let purchaseDateData = parsedBody.subdata(in: price.nextIndex..<(price.nextIndex + 8))
    let purchaseDate = String(data: purchaseDateData, encoding: .isoLatin1)
    var byteOrderHint: String.Encoding?
    let seller = ID3StringCodec.decodeString(
        data: parsedBody.subdata(in: (price.nextIndex + 8)..<parsedBody.count),
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Price": price.value as Any,
        "PurchaseDate": purchaseDate as Any,
        "Seller": seller as Any
    ])
}

private func makeCommercialFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let encodingByte = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let price = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 1, terminated: true)
    guard price.nextIndex + 9 <= parsedBody.count else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "Price": price.value as Any
        ])
    }

    let validUntilData = parsedBody.subdata(in: price.nextIndex..<(price.nextIndex + 8))
    let validUntil = String(data: validUntilData, encoding: .isoLatin1)
    let contactURL = ID3StringCodec.readLatin1String(
        from: parsedBody,
        startingAt: price.nextIndex + 8,
        terminated: true
    )
    guard contactURL.nextIndex < parsedBody.count else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "Price": price.value as Any,
            "ValidUntil": validUntil as Any,
            "ContactURL": contactURL.value as Any
        ])
    }

    let receivedAs = Int(parsedBody[contactURL.nextIndex])
    var byteOrderHint: String.Encoding?
    let seller = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: contactURL.nextIndex + 1,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )
    let description = ID3StringCodec.readEncodedString(
        from: parsedBody,
        startingAt: seller.nextIndex,
        encodingByte: encodingByte,
        byteOrderHint: &byteOrderHint
    )
    let mimeType = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: description.nextIndex, terminated: true)
    let logo = mimeType.nextIndex <= parsedBody.count
        ? parsedBody.subdata(in: mimeType.nextIndex..<parsedBody.count)
        : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "Price": price.value as Any,
        "ValidUntil": validUntil as Any,
        "ContactURL": contactURL.value as Any,
        "ReceivedAs": receivedAs,
        "Seller": seller.value as Any,
        "Description": description.value as Any,
        "MIME type": mimeType.value as Any,
        "Logo": logo
    ])
}

private func makeEncryptionMethodRegistrationFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let owner = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    let methodSymbol = owner.nextIndex < parsedBody.count ? Int(parsedBody[owner.nextIndex]) : 0
    let dataStart = min(owner.nextIndex + 1, parsedBody.count)
    let encryptionData = parsedBody.subdata(in: dataStart..<parsedBody.count)

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "OwnerIdentifier": owner.value as Any,
        "MethodSymbol": methodSymbol,
        "EncryptionData": encryptionData
    ])
}

private func makeGroupIdentificationFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    let owner = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
    let groupSymbol = owner.nextIndex < parsedBody.count ? Int(parsedBody[owner.nextIndex]) : 0
    let dataStart = min(owner.nextIndex + 1, parsedBody.count)
    let groupData = parsedBody.subdata(in: dataStart..<parsedBody.count)

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "OwnerIdentifier": owner.value as Any,
        "GroupSymbol": groupSymbol,
        "GroupData": groupData
    ])
}

private func makeSignatureFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let groupSymbol = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let signature = parsedBody.count > 1 ? parsedBody.subdata(in: 1..<parsedBody.count) : Data()
    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "GroupSymbol": Int(groupSymbol),
        "Signature": signature
    ])
}

private func makeSeekFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 4 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "MinimumOffsetToNextTag": Int(parsedBody.readUInt32BigEndian(at: 0))
    ])
}

private func makeAudioSeekPointIndexFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 12 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    let indexedDataStart = Int(parsedBody.readUInt32BigEndian(at: 0))
    let indexedDataLength = Int(parsedBody.readUInt32BigEndian(at: 4))
    let numberOfPoints = Int(parsedBody.readUInt16BigEndian(at: 8))
    let bitsPerPoint = Int(parsedBody[10])
    let bitsPerFraction = Int(parsedBody[11])
    let pointsData = parsedBody.count > 12 ? parsedBody.subdata(in: 12..<parsedBody.count) : Data()

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "IndexedDataStart": indexedDataStart,
        "IndexedDataLength": indexedDataLength,
        "NumberOfPoints": numberOfPoints,
        "BitsPerPoint": bitsPerPoint,
        "BitsPerFraction": bitsPerFraction,
        "PointsData": pointsData
    ])
}

private func makeEventTimingFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let timestampFormat = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var currentIndex = 1
    var events: [[String: Any]] = []

    while currentIndex + 5 <= parsedBody.count {
        let type = Int(parsedBody[currentIndex])
        let timestamp = Int(parsedBody.readUInt32BigEndian(at: currentIndex + 1))
        events.append([
            "EventType": type,
            "Timestamp": timestamp
        ])
        currentIndex += 5
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "TimestampFormat": Int(timestampFormat),
        "Events": events
    ])
}

private func makeLocationLookupTableFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 10 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "FramesBetweenReference": Int(parsedBody.readUInt16BigEndian(at: 0)),
        "BytesBetweenReference": parsedBody.readUInt24BigEndian(at: 2),
        "MillisecondsBetweenReference": parsedBody.readUInt24BigEndian(at: 5),
        "BitsForBytesDeviation": Int(parsedBody[8]),
        "BitsForMillisecondsDeviation": Int(parsedBody[9]),
        "ReferenceData": parsedBody.subdata(in: 10..<parsedBody.count)
    ])
}

private func makeSynchronisedTempoCodesFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard let timestampFormat = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var currentIndex = 1
    var items: [[String: Any]] = []

    while currentIndex < parsedBody.count {
        guard currentIndex < parsedBody.count else {
            break
        }

        var tempo = Int(parsedBody[currentIndex])
        currentIndex += 1
        if tempo == 0xFF, currentIndex < parsedBody.count {
            tempo += Int(parsedBody[currentIndex])
            currentIndex += 1
        }

        guard currentIndex + 4 <= parsedBody.count else {
            break
        }

        let timestamp = Int(parsedBody.readUInt32BigEndian(at: currentIndex))
        currentIndex += 4
        items.append([
            "Tempo": tempo,
            "Timestamp": timestamp
        ])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "TimestampFormat": Int(timestampFormat),
        "Items": items
    ])
}

private func makeRelativeVolumeFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    if header.frameID == "RVA2" {
        let identification = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 0, terminated: true)
        var currentIndex = identification.nextIndex
        var adjustments: [[String: Any]] = []

        while currentIndex + 4 <= parsedBody.count {
            let channelType = Int(parsedBody[currentIndex])
            let volumeAdjustment = Int(Int16(bitPattern: parsedBody.readUInt16BigEndian(at: currentIndex + 1)))
            let bitsUsed = Int(parsedBody[currentIndex + 3])
            currentIndex += 4

            let peakByteCount = max(1, (bitsUsed + 7) / 8)
            guard currentIndex + peakByteCount <= parsedBody.count else {
                break
            }

            let peakVolume = parsedBody.subdata(in: currentIndex..<(currentIndex + peakByteCount)).readVariableLengthInteger()
            currentIndex += peakByteCount
            adjustments.append([
                "ChannelType": channelType,
                "VolumeAdjustment": volumeAdjustment,
                "BitsUsed": bitsUsed,
                "PeakVolume": peakVolume
            ])
        }

        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "Identification": identification.value as Any,
            "Adjustments": adjustments
        ])
    }

    guard parsedBody.count >= 2 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    var details: [String: Any] = [
        "AdjustmentBits": Int(parsedBody[1]),
        "IncrementDecrementFlags": Int(parsedBody[0])
    ]

    if parsedBody.count > 2 {
        details["Data"] = parsedBody.subdata(in: 2..<parsedBody.count)
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: details)
}

private func makeEqualisationFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    if header.frameID == "EQU2" {
        guard parsedBody.count >= 2 else {
            return StructuredFrame(header: header, rawBody: rawBody, details: [:])
        }

        let interpolationMethod = Int(parsedBody[0])
        let identification = ID3StringCodec.readLatin1String(from: parsedBody, startingAt: 1, terminated: true)
        let adjustments = identification.nextIndex <= parsedBody.count
            ? parsedBody.subdata(in: identification.nextIndex..<parsedBody.count)
            : Data()

        return StructuredFrame(header: header, rawBody: rawBody, details: [
            "InterpolationMethod": interpolationMethod,
            "Identification": identification.value as Any,
            "AdjustmentData": adjustments
        ])
    }

    guard let adjustmentBits = parsedBody.first else {
        return StructuredFrame(header: header, rawBody: rawBody, details: [:])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "AdjustmentBits": Int(adjustmentBits),
        "AdjustmentData": parsedBody.count > 1 ? parsedBody.subdata(in: 1..<parsedBody.count) : Data()
    ])
}

private func makeReverbFrame(header: ID3FrameHeader, rawBody: Data, parsedBody: Data) -> StructuredFrame {
    guard parsedBody.count >= 12 else {
        return StructuredFrame(header: header, rawBody: rawBody, details: ["Data": parsedBody])
    }

    return StructuredFrame(header: header, rawBody: rawBody, details: [
        "ReverbLeft": Int(parsedBody.readUInt16BigEndian(at: 0)),
        "ReverbRight": Int(parsedBody.readUInt16BigEndian(at: 2)),
        "BouncesLeft": Int(parsedBody[4]),
        "BouncesRight": Int(parsedBody[5]),
        "FeedbackLeftToLeft": Int(parsedBody[6]),
        "FeedbackLeftToRight": Int(parsedBody[7]),
        "FeedbackRightToRight": Int(parsedBody[8]),
        "FeedbackRightToLeft": Int(parsedBody[9]),
        "PremixLeftToRight": Int(parsedBody[10]),
        "PremixRightToLeft": Int(parsedBody[11])
    ])
}

extension Data {
    func readUInt32BigEndian(at index: Int) -> UInt32 {
        guard index + 4 <= count else {
            return 0
        }

        return withUnsafeBytes { pointer in
            let start = pointer.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self)
            return UInt32(start[0]) << 24
                | UInt32(start[1]) << 16
                | UInt32(start[2]) << 8
                | UInt32(start[3])
        }
    }

    func readUInt16BigEndian(at index: Int) -> UInt16 {
        guard index + 2 <= count else {
            return 0
        }

        return withUnsafeBytes { pointer in
            let start = pointer.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self)
            return UInt16(start[0]) << 8 | UInt16(start[1])
        }
    }

    func readUInt24BigEndian(at index: Int) -> Int {
        guard index + 3 <= count else {
            return 0
        }

        return withUnsafeBytes { pointer in
            let start = pointer.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self)
            return Int(start[0]) << 16 | Int(start[1]) << 8 | Int(start[2])
        }
    }

    func readSynchsafeInt(at index: Int, length: Int = 4) -> Int {
        guard index + length <= count else {
            return 0
        }

        var value = 0
        for offset in 0..<length {
            value = (value << 7) | Int(self[index + offset] & 0x7F)
        }
        return value
    }

    func readVariableLengthInteger() -> UInt64 {
        reduce(0) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    func deunsynchronized() -> Data {
        guard count > 1 else {
            return self
        }

        var result = Data()
        result.reserveCapacity(count)

        var index = 0
        while index < count {
            let byte = self[index]
            result.append(byte)

            if byte == 0xFF, index + 1 < count, self[index + 1] == 0x00 {
                index += 2
            } else {
                index += 1
            }
        }

        return result
    }

    func zlibDecompressed(expectedSize: Int?) -> Data? {
        guard !isEmpty else {
            return Data()
        }

        let destinationCapacity = Swift.max(expectedSize ?? (count * 4), count * 2, 64)
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }

        return withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }

            var output = Data(count: destinationCapacity)
            let decompressedCount = output.withUnsafeMutableBytes { destinationBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    sourceBase,
                    count,
                    scratch,
                    COMPRESSION_ZLIB
                )
            }

            guard decompressedCount > 0 else {
                return nil
            }

            output.removeSubrange(decompressedCount..<output.count)
            return output
        }
    }
}
