# MP3 Chapter Reader

A Swift package for extracting ID3v2 tags from MP3 files, with special focus on chapter frames. This package allows you to read and parse ID3v2 tags from MP3 files, including text frames, picture frames, link frames, and chapter frames.

## Features

- Read ID3v2 tags from MP3 files (supports ID3v2.2, ID3v2.3, and ID3v2.4)
- Extract text frames (title, artist, album, etc.)
- Extract picture frames (album art, etc.)
- Extract link frames (URLs)
- Extract chapter frames with subframes
- Robust error handling and text encoding support
- Comprehensive documentation

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the package to your Xcode project:

1. In Xcode, select "File" > "Add Packages..."
2. Enter the repository URL: `https://github.com/holgerkrupp/mp3ChapterReader.git`
3. Click "Add Package"

## Usage

### Basic Usage

```swift
import mp3ChapterReader

// Initialize the reader with a file URL
if let mp3Reader = mp3ChapterReader(with: url) {
    // Get a dictionary of all ID3v2 frames
    let dict = mp3Reader.getID3Dict()
    
    // Access specific frames
    if let title = dict["TIT2"] as? String {
        print("Title: \(title)")
    }
    
    // Access chapters
    if let chaptersDict = dict["Chapters"] as? [String: [String: Any]] {
        for (id, chapter) in chaptersDict {
            print("Chapter \(id): \(chapter)")
        }
    }
}
```

### Working with Chapters

The package provides comprehensive support for ID3v2 chapter frames. Each chapter can contain various subframes, such as title, subtitle, picture, and link frames.

```swift
import mp3ChapterReader

if let mp3Reader = mp3ChapterReader(with: url) {
    let dict = mp3Reader.getID3Dict()
    
    if let chaptersDict = dict["Chapters"] as? [String: [String: Any]] {
        var chapters: [Chapter] = []
        
        for (_, chapter) in chaptersDict {
            let newChapter = Chapter()
            
            // Extract chapter information
            newChapter.title = chapter["TIT2"] as? String ?? ""
            newChapter.subtitle = chapter["TIT3"] as? String ?? ""
            newChapter.start = chapter["startTime"] as? Double ?? 0
            newChapter.duration = (chapter["endTime"] as? Double ?? 0) - (newChapter.start ?? 0)
            
            // Extract link if available
            if let url = chapter["WXXX"] as? [String: Any],
               let urlString = url["Url"] as? String {
                newChapter.link = URL(string: urlString)
            }
            
            // Extract image if available
            if let apic = chapter["APIC"] as? [String: Any],
               let imageData = apic["Data"] as? Data {
                newChapter.imageData = imageData
            }
            
            chapters.append(newChapter)
        }
        
        // Use the chapters in your app
        // ...
    }
}
```

### Frame Flags

The package supports parsing frame flags, which provide information about how frames should be handled:

```swift
if let mp3Reader = mp3ChapterReader(with: url) {
    let dict = mp3Reader.getID3Dict()
    
    if let tit2 = dict["TIT2"] as? [String: Any],
       let flags = tit2["flags"] as? [String: Any] {
        let isReadOnly = flags["readOnly"] as? Bool ?? false
        let isCompressed = flags["compressed"] as? Bool ?? false
        
        print("Title frame is read-only: \(isReadOnly)")
        print("Title frame is compressed: \(isCompressed)")
    }
}
```

## License

This package is available under the MIT license. See the LICENSE file for more info.

