# MP3 Chapter Reader

A Swift package for extracting ID3 tags from MP3 files, with special focus on chapter frames. The package reads ID3v2.2, ID3v2.3, and ID3v2.4 tags from local or remote MP3 files and parses a broad range of standard frame families, including chapters and tables of contents.

## Features

- Read ID3v2 tags from MP3 files (supports ID3v2.2, ID3v2.3, and ID3v2.4)
- Read tags from local files and remote URLs
- Extract standard text, URL, picture, comment, lyrics, private, counter, and binary frame families
- Extract chapter (`CHAP`) frames with embedded subframes
- Extract table of contents (`CTOC`) frames
- Preserve duplicate frame values instead of silently dropping later entries
- Handle version-specific frame headers and frame sizes correctly
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

The package provides comprehensive support for ID3 chapter frames. Each chapter can contain various subframes, such as title, subtitle, picture, and link frames. Table-of-contents frames are also exposed separately under `TableOfContents`.

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

### Frame Output

`getID3Dict()` keeps simple text and URL frames easy to consume:

```swift
if let mp3Reader = mp3ChapterReader(with: url) {
    let dict = mp3Reader.getID3Dict()

    let title = dict["TIT2"] as? String
    let purchaseLink = dict["WCOM"] as? String
}
```

Structured frames are returned as dictionaries:

```swift
if let mp3Reader = mp3ChapterReader(with: url) {
    let dict = mp3Reader.getID3Dict()

    if let comment = dict["COMM"] as? [String: Any] {
        print(comment["Language"] ?? "")
        print(comment["Comment"] ?? "")
    }
}
```

If the same frame occurs more than once, the resulting value becomes an array.

## License

This package is available under the MIT license. See the LICENSE file for more info.
