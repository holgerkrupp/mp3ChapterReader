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
    
    func convertArrayToDictionaries<T: Decodable>(_ instances: [T]) -> [[String: Any]] {
        return instances.map { convertToDictionary($0) }
    }
    
    func convertToDictionary<T: Decodable>(_ instance: T) -> [String: Any] {
        let mirror = Mirror(reflecting: instance)
        var dictionary: [String: Any] = [:]
        
        for child in mirror.children {
            if let key = child.label {
                dictionary[key] = child.value
            }
        }
        
        return dictionary
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
