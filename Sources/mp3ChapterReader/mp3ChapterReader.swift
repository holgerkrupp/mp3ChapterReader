//
//  File.swift
//  
//
//  Created by Holger Krupp on 02.03.24.
//

import Foundation

/// A class for reading ID3v2 tags from MP3 files, with special focus on chapter frames
public class mp3ChapterReader {
    
    /// The raw file data
    private var fileData: Data
    
    /// The extracted ID3v2 frames
    public var frames: [Frame] = []
    
    /// The ID3v2 version (e.g., 2, 3, 4)
    public var version: Int = 0
    
    /// The ID3v2 revision
    public var revision: Int = 0
    
    /// Whether the file has an extended header
    public var hasExtendedHeader: Bool = false
    
    /// Whether the file has experimental indicators
    public var isExperimental: Bool = false
    
    /// Whether the file has a footer
    public var hasFooter: Bool = false
    
    /// Whether the file has unsynchronization
    public var hasUnsynchronization: Bool = false
    
    /// The size of the ID3v2 tag in bytes
    public var tagSize: Int = 0
    
    /// Initialize a new mp3ChapterReader with a file URL
    /// - Parameter fileURL: The URL of the MP3 file to read
    /// - Returns: An initialized mp3ChapterReader or nil if the file cannot be read or doesn't contain an ID3v2 tag
    public init?(with fileURL: URL) {
        do {
            fileData = try Data(contentsOf: fileURL)
            
            // Check if the file starts with "ID3" (indicating it's an ID3v2 tag)
            guard fileData.count >= 10, fileData.prefix(3) == Data("ID3".utf8) else {
                print("Not an ID3v2 tag.")
                return nil
            }
            
            // Parse the ID3v2 tag header
            version = Int(fileData[3])
            revision = Int(fileData[4])
            
            // Check if this is a supported version
            guard version >= 2 && version <= 4 else {
                print("Unsupported ID3v2 version: \(version)")
                return nil
            }
            
            // Parse the flags
            let flags = fileData[5]
            hasUnsynchronization = (flags & 0x80) != 0
            hasExtendedHeader = (flags & 0x40) != 0
            isExperimental = (flags & 0x20) != 0
            hasFooter = (flags & 0x10) != 0
            
            // Parse the tag size (4 bytes, most significant bit of each byte is not used)
            let sizeBytes = fileData.subdata(in: 6..<10)
            tagSize = Int(sizeBytes[0]) << 21 | Int(sizeBytes[1]) << 14 | Int(sizeBytes[2]) << 7 | Int(sizeBytes[3])
            
            // Extract the frames
            frames = extractID3Frames()
            
        } catch {
            print("Error reading file: \(error)")
            return nil
        }
    }
    
    /// Get a dictionary representation of all ID3v2 frames
    /// - Returns: A dictionary containing all frames and chapters
    public func getID3Dict() -> [String: Any] {
        return convertArrayToDictionary(frames)
    }
    
    /// Convert an array of frames to a dictionary
    /// - Parameter instances: The array of frames to convert
    /// - Returns: A dictionary containing all frames and chapters
    private func convertArrayToDictionary<T: Decodable>(_ instances: [T]) -> [String: Any] {
        var framesDictionary: [String: Any] = [:]
        var chaptersDictionary: [String: Any] = [:]
        
        for instance in instances {
            if let frame = instance as? ChapFrame {
                chaptersDictionary[frame.elementID] = frame.createDictionary()
            } else if let frame = instance as? Frame {
                if let frameID = frame.frameID.isEmpty ? nil : frame.frameID {
                    let frameDictionary = frame.createDictionary()
                    framesDictionary.merge(frameDictionary) { old, new in
                        old
                    }
                }
            }
        }
        
        var resultDictionary: [String: Any] = [:]
        
        if !framesDictionary.isEmpty {
            resultDictionary = framesDictionary
        }
        
        if !chaptersDictionary.isEmpty {
            resultDictionary["Chapters"] = chaptersDictionary
        }
        
        return resultDictionary
    }
    
    /// Extract all ID3v2 frames from the file
    /// - Returns: An array of frames
    private func extractID3Frames() -> [Frame] {
        // Skip the extended header, if present
        var currentPosition = 10
        if hasExtendedHeader {
            // Extended header is present
            if version == 4 {
                // ID3v2.4 extended header
                let extendedHeaderSize = Int(fileData.readUInt32BigEndian(at: currentPosition))
                currentPosition += extendedHeaderSize
            } else {
                // ID3v2.3 extended header
                let extendedHeaderSize = Int(fileData.readUInt32BigEndian(at: currentPosition))
                currentPosition += extendedHeaderSize + 4 // +4 for the size bytes
            }
        }
        
        // Read frames until the end of the tag
        var frames: [Frame] = []
        let tagEnd = 10 + tagSize
        
        while currentPosition + 10 <= tagEnd {
            // Check if we have enough data for a frame header
            guard currentPosition + 10 <= fileData.count else {
                print("Error: Unexpected end of file at position \(currentPosition)")
                break
            }
            
            // Read the frame header
            let frameIdentifier = String(data: fileData.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
            
            // Check if we've reached the end of the frames
            if frameIdentifier.isEmpty || frameIdentifier == "\0\0\0\0" {
                break
            }
            
            let frameSizeBytes = fileData.subdata(in: (currentPosition + 4)..<(currentPosition + 8))
            let frameFlags = fileData.readUInt16(at: currentPosition + 8)
            
            // Parse frame size based on version
            var frameSize: Int
            if version == 4 {
                // ID3v2.4: 4 bytes, most significant bit of each byte is not used
                frameSize = Int(frameSizeBytes[0]) << 21 | Int(frameSizeBytes[1]) << 14 | Int(frameSizeBytes[2]) << 7 | Int(frameSizeBytes[3])
            } else {
                // ID3v2.2/2.3: 4 bytes, all bits are used
                frameSize = Int(frameSizeBytes.readUInt32BigEndian(at: 0))
            }
            
            // Parse frame flags based on version
            var formatFlags1: UInt16 = 0
            var formatFlags2: UInt16 = 0
            
            if version == 4 {
                formatFlags1 = frameFlags & 0b1100000000000000
                formatFlags2 = frameFlags & 0b0011111100000000
            } else {
                formatFlags1 = frameFlags & 0b1100000000000000
                formatFlags2 = frameFlags & 0b0011000000000000
            }
            
            // Check if we have enough data for the frame
            guard currentPosition + 10 + frameSize <= fileData.count else {
                print("Error: Incomplete frame data at position \(currentPosition) in \(fileData.count)")
                break
            }
            
            // Adjust frame size if needed
            var adjustedFrameSize = frameSize
            if version == 4 && (formatFlags2 & 0b0001000000000000) != 0 {
                // Data length indicator is present
                adjustedFrameSize += 4
            }
            
            // Extract frame data
            let frameData = fileData.subdata(in: (currentPosition)..<(currentPosition + 10 + adjustedFrameSize))
            
            // Create the appropriate frame instance
            let frame = Frame.createInstance(data: frameData)
            frames.append(frame)
            
            // Move to the next frame
            currentPosition += (10 + adjustedFrameSize)
        }
        
        return frames
    }
}
