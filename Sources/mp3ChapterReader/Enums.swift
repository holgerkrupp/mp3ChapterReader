//
//  File.swift
//  
//
//  Created by Holger Krupp on 02.03.24.
//

import Foundation

public enum PictureType: UInt8, CustomStringConvertible {
    case other = 0x00
    case fileIcon32x32 = 0x01
    case otherFileIcon = 0x02
    case coverFront = 0x03
    case coverBack = 0x04
    case leafletPage = 0x05
    case media = 0x06
    case leadArtist = 0x07
    case artist = 0x08
    case conductor = 0x09
    case bandOrchestra = 0x0A
    case composer = 0x0B
    case lyricist = 0x0C
    case recordingLocation = 0x0D
    case duringRecording = 0x0E
    case duringPerformance = 0x0F
    case movieScreenCapture = 0x10
    case brightColouredFish = 0x11
    case illustration = 0x12
    case bandArtistLogotype = 0x13
    case publisherLogotype = 0x14
    
    public var description: String {
        switch self {
        case .other: return "Other"
        case .fileIcon32x32: return "32x32 pixels 'file icon' (PNG only)"
        case .otherFileIcon: return "Other file icon"
        case .coverFront: return "Cover (front)"
        case .coverBack: return "Cover (back)"
        case .leafletPage: return "Leaflet page"
        case .media: return "Media (e.g. label side of CD)"
        case .leadArtist: return "Lead artist/lead performer/soloist"
        case .artist: return "Artist/performer"
        case .conductor: return "Conductor"
        case .bandOrchestra: return "Band/Orchestra"
        case .composer: return "Composer"
        case .lyricist: return "Lyricist/text writer"
        case .recordingLocation: return "Recording Location"
        case .duringRecording: return "During recording"
        case .duringPerformance: return "During performance"
        case .movieScreenCapture: return "Movie/video screen capture"
        case .brightColouredFish: return "A bright coloured fish"
        case .illustration: return "Illustration"
        case .bandArtistLogotype: return "Band/artist logotype"
        case .publisherLogotype: return "Publisher/Studio logotype"
        }
    }
}
