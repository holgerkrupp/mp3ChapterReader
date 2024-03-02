//
//  File.swift
//  
//
//  Created by Holger Krupp on 02.03.24.
//

import Foundation

public class mp3ChapterReader{
    
    public init(){}
    
    public func getID3Dict(from fileURL: URL) -> [[String: Any]] {
        
        let frames = extractID3Frames(from: fileURL)
        
       return convertArrayToDictionaries(frames)
        
        
    }
    
    // Function to convert an object to a dictionary
    func convertToDictionary(_ instance: Any) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        
        if let instance = instance as? Frame {
            dictionary["frameID"] = instance.frameID
            dictionary["size"] = instance.size
            dictionary["flags"] = instance.flags
            
            if let titleFrame = instance as? TitleFrame {
                dictionary["textEncoding"] = titleFrame.textEncoding
                dictionary["information"] = titleFrame.information
            } else if let pictureFrame = instance as? PictureFrame {
                dictionary["mimeType"] = pictureFrame.mimeType
                dictionary["type"] = pictureFrame.type
                dictionary["description"] = pictureFrame.description
            } else if let linkFrame = instance as? LinkFrame {
                dictionary["textEncoding"] = linkFrame.textEncoding
                dictionary["description"] = linkFrame.description
                dictionary["url"] = linkFrame.url
            } else if let chapFrame = instance as? ChapFrame {
                dictionary["elementID"] = chapFrame.elementID
                dictionary["startTime"] = chapFrame.startTime
                dictionary["endTime"] = chapFrame.endTime
                dictionary["startOffset"] = chapFrame.startOffset
                dictionary["endOffset"] = chapFrame.endOffset
                dictionary["frames"] = chapFrame.frames.map { convertToDictionary($0) }
            }
            
            // Handle other subclasses...
            
            // Handle common properties for all subclasses
            // ...
        }
        
        return dictionary
    }
    
    // Function to convert an array of objects to an array of dictionaries
    func convertArrayToDictionaries(_ instances: [Any]) -> [[String: Any]] {
        return instances.map { convertToDictionary($0) }
    }
    
    
    
    public func extractID3Frames(from fileURL: URL) -> [Frame] {
        do {
            // Read the entire file into Data
            let fileData = try Data(contentsOf: fileURL)
            
            // Check if the file starts with "ID3" (indicating it's an ID3v2 tag)
            guard fileData.count >= 3, fileData.prefix(3) == Data("ID3".utf8) else {
                print("Not an ID3v2 tag.")
                return []
            }
            
            // Parse the ID3v2 tag header
            let version = fileData[3]
            let flags = fileData[5]
            
            // Skip the extended header, if present
            var currentPosition = 10
            if (flags & 0x40) != 0 {
                // Extended header is present
                // Extract the size of the extended header and skip it
                let extendedHeaderSize = Int(fileData.readUInt32BigEndian(at: currentPosition))
                currentPosition += (10 + extendedHeaderSize)
            }
            
            // Read frames until the end of the file
            var frames: [Frame] = []
            
            while currentPosition + 10 <= fileData.count {
                // Add a check for frame data length
                
                let frameIdentifier = String(data: fileData.subdata(in: currentPosition..<(currentPosition + 4)), encoding: .utf8) ?? ""
                let frameSizeBytes = fileData.subdata(in: (currentPosition + 4)..<(currentPosition + 8))
                let frameFlags = fileData.readUInt16(at: currentPosition + 8)
                let formatFlags2 = frameFlags & 0b0001000000000000
                let frameSize = Int(frameSizeBytes.readUInt32BigEndian(at: 0))
                let formatFlags1 = (frameFlags >> 8) & 0b00001111
                
                
                guard currentPosition + 10 + frameSize <= fileData.count else {
                    print("Error: Incomplete frame data at position \(currentPosition) in \(fileData.count)")
                    print("Remaining data: \(fileData.subdata(in: currentPosition..<fileData.count))")
                    break
                }
                
                
                var adjustedFrameSize = frameSize
                if (formatFlags2 & 0b0001000000000000) != 0 {
                    // Additional information follows the frame header
                    adjustedFrameSize += 4
                }
                
                // Extract frame data
                let frameData = fileData.subdata(in: (currentPosition)..<(currentPosition + 10 + adjustedFrameSize))
                
                /*
                 
                 */
                // Append the frame to the frames array
                frames.append(Frame(data: frameData))
                
                // Move to the next frame
                currentPosition += (10 + adjustedFrameSize)
                
                
            }
            
            return frames
        } catch {
            print("Error reading file: \(error)")
            return []
        }
    }
    
}
