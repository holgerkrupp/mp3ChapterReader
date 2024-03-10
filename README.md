A simple package to extract id3 Frames from mp3 files


## How to use the chapter directory

The .getID3Dict generates a dictionary of the identified ID3 Frames as a swift dictionary. The first level contains all the frames related to the file (title, artist,…). The value to the key "Chapters" contains a dictionary with all chapters. Each chapter contains the basic elements like totle, startTime, endTime on the upper level. Additional subframes, like pictures (APIC) or links (WXXX) also integrated.

This is how i use it at the moment (06. March 2024) in my app Raúl:

 >           if let mp3Reader = mp3ChapterReader(with: url){
 >               let dict = mp3Reader.getID3Dict()
 >               if let chaptersDict = dict["Chapters"] as? [String:[String:Any]]{
 >                   var chapters: [Chapter] = []
 >                   for chapter in chaptersDict {
 >                       let newChaper = Chapter()
 >                       newChaper.title = chapter.value["Title"] as? String ?? ""
 >                       newChaper.start = chapter.value["startTime"] as? Double ?? 0
 >                      
 >                       newChaper.duration = (chapter.value["endTime"] as? Double ?? 0) - (newChaper.start ?? 0)
 >                       newChaper.type = .embedded
 >                       if let imagedata = (chapter.value["APIC"] as? [String:Any])?["Data"] as? Data{
 >                           newChaper.imageData = imagedata
 >                       }
 >                       chapters.append(newChaper)
 >                   }
 >                   return chapters
 >               }
 >            }

