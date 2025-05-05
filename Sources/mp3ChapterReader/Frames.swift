// The Swift Programming Language
// https://docs.swift.org/swift-book


// ID3v24 Spec: https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.4.0-frames.html#wxxx
// ID3v2 Chaper Spec: https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2-chapters-1.0.html#declared-id3v2-frames

import Foundation

let headerSize = 10


func getEndcoding(with data: UInt8) -> String.Encoding{
    
    
    switch data {
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

public class Frame: Decodable {
    
    var frameID:String = ""
    var size:Int = 0 // size of the frame, excluding the header
    var flags:Data?
    
    // Frame status flags
    var isTagAlterPreservation: Bool = false
    var isFileAlterPreservation: Bool = false
    var isReadOnly: Bool = false
    
    // Frame format flags
    var isGroupingIdentity: Bool = false
    var isCompressed: Bool = false
    var isEncrypted: Bool = false
    var isUnsynchronized: Bool = false
    var hasDataLengthIndicator: Bool = false
    
    required init(data:Data){
        var currentPosition = 0  // 4 if the identifier would be part of the data
        
        // Check if we have enough data for a frame header
        guard data.count >= 10 else {
            print("Error: Frame data too short")
            return
        }
        
        frameID = String(data: data.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
        currentPosition += 4
        
        let frameSizeBytes = data.subdata(in: (currentPosition)..<(currentPosition + 4))
        size = Int(frameSizeBytes.readUInt32BigEndian(at: 0))
        currentPosition += 4
        
        // Store the raw flags
        flags = data.subdata(in: currentPosition..<currentPosition+2)
        
        // Parse status flags (first byte)
        if let flagsData = flags, flagsData.count >= 1 {
            let statusFlags = flagsData[0]
            isTagAlterPreservation = (statusFlags & 0x80) != 0
            isFileAlterPreservation = (statusFlags & 0x40) != 0
            isReadOnly = (statusFlags & 0x20) != 0
        }
        
        // Parse format flags (second byte)
        if let flagsData = flags, flagsData.count >= 2 {
            let formatFlags = flagsData[1]
            isGroupingIdentity = (formatFlags & 0x80) != 0
            isCompressed = (formatFlags & 0x08) != 0
            isEncrypted = (formatFlags & 0x04) != 0
            isUnsynchronized = (formatFlags & 0x02) != 0
            hasDataLengthIndicator = (formatFlags & 0x01) != 0
        }
    }
    
    func createDictionary() -> [String:Any]{
        var dict: [String:Any] = [:]
        dict[frameID] = frameID
        
        // Add flag information to the dictionary
        var flagsDict: [String: Any] = [:]
        flagsDict["tagAlterPreservation"] = isTagAlterPreservation
        flagsDict["fileAlterPreservation"] = isFileAlterPreservation
        flagsDict["readOnly"] = isReadOnly
        flagsDict["groupingIdentity"] = isGroupingIdentity
        flagsDict["compressed"] = isCompressed
        flagsDict["encrypted"] = isEncrypted
        flagsDict["unsynchronized"] = isUnsynchronized
        flagsDict["dataLengthIndicator"] = hasDataLengthIndicator
        
        dict["flags"] = flagsDict
        
        return dict
    }
    
    
    enum CodingKeys: String, CodingKey {
        case frameID, size, flags
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameID = try container.decode(String.self, forKey: .frameID)
        size = try container.decode(Int.self, forKey: .size)
        flags = try container.decodeIfPresent(Data.self, forKey: .flags)
        
        // Parse flags if available
        if let flagsData = flags, flagsData.count >= 2 {
            // Parse status flags (first byte)
            let statusFlags = flagsData[0]
            isTagAlterPreservation = (statusFlags & 0x80) != 0
            isFileAlterPreservation = (statusFlags & 0x40) != 0
            isReadOnly = (statusFlags & 0x20) != 0
            
            // Parse format flags (second byte)
            let formatFlags = flagsData[1]
            isGroupingIdentity = (formatFlags & 0x80) != 0
            isCompressed = (formatFlags & 0x08) != 0
            isEncrypted = (formatFlags & 0x04) != 0
            isUnsynchronized = (formatFlags & 0x02) != 0
            hasDataLengthIndicator = (formatFlags & 0x01) != 0
        }
    }
    
    class func createInstance(data: Data) -> Frame {
        
        var currentPosition = 0  // 4 if the identifier would be part of the data
        
        let frameType = String(data: data.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
        currentPosition += 4
        
        
        switch frameType {
            
        case "CHAP":
            return ChapFrame(data: data)
            
        case "TIT1", "TIT2", "TIT3", "TALB", "TOAL", "TRCK", "TPOS", "TSST", "TSRC", "TPE1", "TPE2", "TPE3", "TPE4", "TOPE", "TEXT", "TOLY", "TCOM", "TMCL", "TIPL", "TENC":
            return TextFrame(data: data)

        case "APIC":
            return PictureFrame(data: data)
            
        case "WXXX":
            return LinkFrame(data: data)
        default:
            return Frame(data: data)
        }
    }
    
    
    
    
    func extractTitle(from data: Data) -> (title: String?, encoding: String.Encoding, offset: Int?){
        // Check if we have enough data
        guard data.count > 0 else {
            print("Error: Empty data in extractTitle")
            return (title: nil, encoding: .isoLatin1, offset: 0)
        }
        
        var currentPosition = 0
        let subFrameEnd = data.count
        
        // Get the encoding byte
        let encodingByte = data[currentPosition]
        let encoding = getEndcoding(with: encodingByte)
        
        currentPosition += 1
        
        // If we don't have any more data after the encoding byte
        guard currentPosition < subFrameEnd else {
            print("Error: No data after encoding byte")
            return (title: nil, encoding: encoding, offset: currentPosition)
        }
        
        var endofString = subFrameEnd
        var foundNull = false
        
        // Try to find null termination based on encoding
        if encoding == .utf16 || encoding == .utf16BigEndian {
            // For UTF-16, we need to look for null bytes in pairs
            for i in stride(from: currentPosition, to: subFrameEnd - 1, by: 2) {
                guard i + 1 < data.count else { break }
                
                if data[i] == 0 && data[i+1] == 0 {
                    endofString = i
                    foundNull = true
                    break
                }
            }
        } else {
            // For other encodings, look for a single null byte
            if let nullIndex = data[currentPosition..<subFrameEnd].firstIndex(of: 0) {
                endofString = nullIndex
                foundNull = true
            }
        }
        
        // Ensure we don't try to create a subdata that's out of bounds
        guard currentPosition <= endofString, endofString <= data.count else {
            print("Error: Invalid string bounds (currentPosition: \(currentPosition), endofString: \(endofString), data.count: \(data.count))")
            return (title: nil, encoding: encoding, offset: currentPosition)
        }
        
        // Extract the string with the detected encoding
        let stringData = data.subdata(in: currentPosition..<endofString)
        
        // Only warn about missing null termination if the string appears to be truncated
        if !foundNull && endofString < subFrameEnd {
            print("Warning: No null termination found in \(encoding) data, using full length")
        }
        
        // Try to decode with the specified encoding
        if let extractedString = String(data: stringData, encoding: encoding) {
            return (title: extractedString, encoding: encoding, offset: endofString)
        } else {
            // If the original encoding failed, try ISO-8859-1 as a fallback
            if encoding != .isoLatin1, 
               let fallbackString = String(data: stringData, encoding: .isoLatin1) {
                print("Warning: Failed to decode with \(encoding), falling back to ISO-8859-1")
                return (title: fallbackString, encoding: .isoLatin1, offset: endofString)
            }
            
            // If all else fails, try UTF-8
            if encoding != .utf8,
               let utf8String = String(data: stringData, encoding: .utf8) {
                print("Warning: Failed to decode with \(encoding) and ISO-8859-1, falling back to UTF-8")
                return (title: utf8String, encoding: .utf8, offset: endofString)
            }
            
            print("Error: Unable to decode data with any encoding")
            return (title: nil, encoding: encoding, offset: currentPosition)
        }
    }
    

    
    
    
    
}

public class TextFrame:Frame{
    var textEncoding:String.Encoding = .isoLatin1
    var information:String?
    
    
    
   
    required init(data: Data) {
        super.init(data: data)
        
        let frameDataStart = headerSize
        let frameDataEnd = headerSize + size
        guard data.count >= frameDataEnd else {
            print("Frame data is incomplete")
            textEncoding = .utf8
            information = ""
            return
        }

        let stringData = data.subdata(in: frameDataStart..<frameDataEnd)
        let extracted = extractTitle(from: stringData)
        textEncoding = extracted.encoding
        information = extracted.title
    }
    
    override func createDictionary() -> [String:Any]{
        var dict: [String:Any] = [:]
  //      dict["FrameID"] = frameID
        if frameID == "TIT1"{
            dict["Title"] = information
        }
            dict[frameID] = information
        return dict
    }
    
    enum TitleCodingKeys: String, CodingKey {
        case textEncoding, information
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TitleCodingKeys.self)

        // Decode the raw value from the container
        let rawTextEncoding = try container.decode(UInt8.self, forKey: .textEncoding)
        
        // Use the provided function to get the String.Encoding
        textEncoding = getEndcoding(with: rawTextEncoding)

        information = try container.decodeIfPresent(String.self, forKey: .information)
        
        // Call the designated initializer of the superclass
        try super.init(from: decoder)
    }
}

public class PictureFrame:Frame{
    var mimeType:String?
    var type:PictureType?
    var description:String?
    var image:Data?
    
    
    required init(data:Data){
        super.init(data: data)
        let subFrameEnd = headerSize + size
        
        var currentPosition = headerSize
        let stringData = data.subdata(in: currentPosition..<subFrameEnd)
        let extracted = extractTitle(from: stringData)
        mimeType = extracted.title
        
        
        currentPosition += extracted.offset ?? 0
        
        type = PictureType(rawValue: data[currentPosition])
        
        currentPosition += 1
        print("currentPosition \(currentPosition)")
        let descData = data.subdata(in: currentPosition..<subFrameEnd)
        let extractedDescription = extractTitle(from: descData)
        description = extractedDescription.title
        dump(description)
        currentPosition += extractedDescription.offset ?? 1
        currentPosition += 1
        print("currentPosition \(currentPosition)")
        print("extracted offset: \(extractedDescription.offset)")
        print("image data from \(currentPosition.description) until \(subFrameEnd.description)")

        if currentPosition < subFrameEnd{
            image = data.subdata(in: currentPosition..<subFrameEnd)
            if #available(iOS 16.0, *) {
            var fileManager = FileManager.default
            var docPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            
                if let  path = docPath?.appending(component: subFrameEnd.description.appending(".jpg")).path(){
                    fileManager.createFile(atPath: path, contents: image)
                    print(path)
                }
            } 
        }else{
            print("Image issue: Position: \(currentPosition)- subFrameEnd: \(subFrameEnd) - size: \(size+headerSize)")
        }
    }
    
    override func createDictionary() -> [String:Any]{
        var imagedict: [String:Any] = [:]
    //    imagedict["FrameID"] = frameID
        imagedict["Description"] = description
        imagedict["Type"] = type?.description ?? ""
        imagedict["MIME type"] = mimeType
        imagedict["Data"] = image
        
        var key = frameID
        
        if let type = imagedict["Type"]{
            key.append(" : \(type)")
        }
        
        let dict:[String:Any] = [frameID:imagedict]
        return dict
    }
    
    enum PictureCodingKeys: String, CodingKey {
        case mimeType, type, description, image
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PictureCodingKeys.self)
        
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
        
        // Decode the raw value from the container and directly use PictureType enum
        type = try container.decodeIfPresent(PictureType.self, forKey: .type)
        
        // Call the designated initializer of the superclass
        try super.init(from: decoder)
    }
}

public class LinkFrame:Frame{
    var textEncoding:String.Encoding = .isoLatin1
    var description:String?
    var url:URL?
    
    
    required init(data:Data){
        super.init(data: data)
        let subFrameEnd = headerSize + size
        var currentPosition = headerSize
        
        let stringData = data.subdata(in: headerSize..<size+headerSize)
        let extracted = extractTitle(from: stringData)
        textEncoding = extracted.encoding
        description = extracted.title
        
        
        
        currentPosition += extracted.offset ?? 0
        currentPosition += 1
    
        if let string = String(data: data.subdata(in: (currentPosition..<subFrameEnd)), encoding: .isoLatin1){
            url = URL(string: string)
        }
    }
    
    override func createDictionary() -> [String:Any]{
        var dict: [String:Any] = [:]
        dict["FrameID"] = frameID
        dict["Description"] = description
        dict["Url"] = url
        return dict
    }
    
    
    
    
    enum LinkCodingKeys: String, CodingKey {
        case textEncoding, description, url
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LinkCodingKeys.self)
        
        // Decode the raw value from the container and directly use String.Encoding
        let rawTextEncoding = try container.decode(UInt8.self, forKey: .textEncoding)
        textEncoding = getEndcoding(with: rawTextEncoding)
        
        description = try container.decodeIfPresent(String.self, forKey: .description)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        
        // Call the designated initializer of the superclass
        try super.init(from: decoder)
    }
}


public class ChapFrame:Frame{
    
    var elementID:String = ""
    var startTime:Double = 0 // in milliseconds
    var endTime:Double = 0  // in milliseconds
    var startOffset:Int = 0
    var endOffset:Int = 0
    
    var frames:[Frame] = []
    
    required init(data:Data){
        super.init(data: data)
        
        // CHAP Frame Required Elements Starting after the Header data (always 10 bytes)
        var currentPosition = headerSize
        
        // Safety check for minimum data length
        guard data.count >= currentPosition + 1 else {
            print("Error: Not enough data for CHAP frame header")
            return
        }
        
        // Read text encoding byte for elementID
        let textEncoding = getEndcoding(with: data[currentPosition])
        currentPosition += 1
        
        // Read elementID with proper encoding
        if let range = data[currentPosition..<min(currentPosition+size, data.count)].range(of: Data([0])) {
            let nullTerminatedData = data.subdata(in: (currentPosition..<range.lowerBound))
            elementID = String(data: nullTerminatedData, encoding: textEncoding) ?? ""
            currentPosition = range.lowerBound + 1 // move passed NULL-terminator
        }
        
        // Safety check for timestamps and offsets
        guard currentPosition + 16 <= data.count else {
            print("Error: Not enough data for CHAP frame timestamps and offsets")
            return
        }
        
        // Read timestamps and offsets
        startTime = Double(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        endTime = Double(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        startOffset = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        endOffset = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        // Read subframes with proper boundary checking
        while currentPosition < headerSize + size {
            let remainingSize = headerSize + size - currentPosition
            guard remainingSize >= 10 else { break } // Minimum frame size
            
            // Safety check for subframe data
            guard currentPosition + remainingSize <= data.count else {
                print("Error: Subframe data extends beyond available data")
                break
            }
            
            let subFrameData = data.subdata(in: currentPosition..<min(currentPosition + remainingSize, data.count))
            let newFrame = Frame.createInstance(data: subFrameData)
            frames.append(newFrame)
            currentPosition += newFrame.size + headerSize
        }
    }
    
    enum ChapCodingKeys: String, CodingKey {
        case elementID, startTime, endTime, startOffset, endOffset, frames
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ChapCodingKeys.self)
        
        elementID = try container.decode(String.self, forKey: .elementID)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decode(Double.self, forKey: .endTime)
        startOffset = try container.decode(Int.self, forKey: .startOffset)
        endOffset = try container.decode(Int.self, forKey: .endOffset)
        
        // Decode the array of frames
        frames = try container.decode([Frame].self, forKey: .frames)
        
        // Call the designated initializer of the superclass
        try super.init(from: decoder)
    }
    
    override func createDictionary() -> [String:Any]{
        var dict: [String:Any] = [:]
      //  dict[elementID] = elementID
        dict["timeScale"] = "seconds"
        dict["startTime"] = startTime / 1000
        dict["endTime"] = endTime / 1000
       // var chapterDict:[String:Any] = [:]
        for frame in frames {
            dict.merge(frame.createDictionary(), uniquingKeysWith: { (current, _) in current })
        }
        return dict
    }
}



extension Data {
    func readUInt32BigEndian(at index: Int) -> UInt32 {
        let bytes: [UInt8] = [self[index], self[index + 1], self[index + 2], self[index + 3]]
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
    
    func readUInt16(at index: Int) -> UInt16 {
        let bytes: [UInt8] = [self[index], self[index + 1]]
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}
