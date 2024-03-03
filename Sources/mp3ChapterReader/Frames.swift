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
    
    required init(data:Data){
        var currentPosition = 0  // 4 if the identifier would be part of the data
        
        frameID = String(data: data.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
        currentPosition += 4
        
        let frameSizeBytes = data.subdata(in: (currentPosition)..<(currentPosition + 4))
        size = Int(frameSizeBytes.readUInt32BigEndian(at: 0))
        currentPosition += 4
        
        flags = data.subdata(in: currentPosition..<currentPosition+2)
    }
    
    enum CodingKeys: String, CodingKey {
        case frameID, size, flags
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameID = try container.decode(String.self, forKey: .frameID)
        size = try container.decode(Int.self, forKey: .size)
        flags = try container.decodeIfPresent(Data.self, forKey: .flags)
    }
    
    
    
    class func createInstance(data: Data) -> Frame {
        
        var currentPosition = 0  // 4 if the identifier would be part of the data
        
        let frameType = String(data: data.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
        currentPosition += 4
        
        switch frameType {
            
        case "CHAP":
            return ChapFrame(data: data)
            
        case "TIT2":
            return TitleFrame(data: data)

        case "APIC":
            return PictureFrame(data: data)
            
        case "WXXX":
            return LinkFrame(data: data)
        default:
            return Frame(data: data)
        }
    }
    
    
    
    
    func extractTitle(from data: Data) -> (title: String?, encoding: String.Encoding, offset: Int?){
        var currentPosition = 0
        let subFrameEnd = data.count
        
        let encodingByte = data[currentPosition]
        let encoding = getEndcoding(with: encodingByte)
        
        
        currentPosition += 1
        var endofString = subFrameEnd
        
        print("- currentPosition - \(currentPosition.description)")
        
        if let utf16String = String(data: data.subdata(in: (currentPosition..<subFrameEnd)), encoding: encoding) {
            // Find the null termination
            if let nullTerminationRange = utf16String.range(of: "\0") {
                endofString = nullTerminationRange.lowerBound.utf16Offset(in: utf16String) + currentPosition
                let nullTerminatedString = utf16String[utf16String.startIndex..<nullTerminationRange.lowerBound]
                return (title: String(nullTerminatedString), encoding: encoding, offset: endofString)
            } else {
                print("No null termination found.")
            }
        } else {
            print("Unable to decode data as UTF-16.")
        }
        
        let information = String(data:  data.subdata(in: (currentPosition..<endofString)), encoding: encoding)
        return (title: information, encoding: encoding, offset: endofString)
    }
    

    
    
    
    
}

public class TitleFrame:Frame{
    var textEncoding:String.Encoding = .isoLatin1
    var information:String?
    
    
    
    required init(data:Data){
        super.init(data: data)
        
        let stringData = data.subdata(in: headerSize..<size+headerSize)
        let extracted = extractTitle(from: stringData)
        textEncoding = extracted.encoding
        information = extracted.title
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
        let stringData = data.subdata(in: currentPosition..<size+headerSize)
        let extracted = extractTitle(from: stringData)
        mimeType = extracted.title
        
        
        currentPosition += extracted.offset ?? 0
        currentPosition += 1
        print("- currentPosition - \(currentPosition.description)")
        
        type = PictureType(rawValue: data[currentPosition])
        
        currentPosition += 1
        let descData = data.subdata(in: currentPosition..<subFrameEnd)
        let extractedDescription = extractTitle(from: descData)
        description = extractedDescription.title
        
        currentPosition += extractedDescription.offset ?? 1
        currentPosition += 1
        
        image = data.subdata(in: currentPosition..<subFrameEnd)
        
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
    
        if let string = String(data: data.subdata(in: (currentPosition..<subFrameEnd)), encoding: .isoLatin1){
            url = URL(string: string)
        }
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
    var startTime:Int = 0 // in milliseconds
    var endTime:Int = 0  // in milliseconds
    var startOffset:Int = 0
    var endOffset:Int = 0
    
    var frames:[Frame] = []
    
    required init(data:Data){
        
        super.init(data: data)

        print("extract CHAMP frame")
    
        // CHAP Frame Required Elements Starting after the Header data (always 10 bytes)
        var currentPosition = headerSize
        if let range = data[currentPosition..<currentPosition+size].range(of: Data([0])) {
            let nullTerminatedData = data.subdata(in: (currentPosition..<range.lowerBound))
            elementID = String(data: nullTerminatedData, encoding: .utf8) ?? ""
            currentPosition = range.lowerBound
            currentPosition += 1 // <- move passed NULL-terminator
        }
        
        startTime = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        endTime = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        startOffset = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        endOffset = Int(data.readUInt32BigEndian(at: currentPosition))
        currentPosition += 4
        
        
        // OPTIONAL SUB FRAMES

        while currentPosition < size + headerSize {
            
            let subFrameData = data.subdata(in: currentPosition..<data.count)
    
            let newFrame =  Frame.createInstance(data: subFrameData)
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
        startTime = try container.decode(Int.self, forKey: .startTime)
        endTime = try container.decode(Int.self, forKey: .endTime)
        startOffset = try container.decode(Int.self, forKey: .startOffset)
        endOffset = try container.decode(Int.self, forKey: .endOffset)
        
        // Decode the array of frames
        frames = try container.decode([Frame].self, forKey: .frames)
        
        // Call the designated initializer of the superclass
        try super.init(from: decoder)
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
