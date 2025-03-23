//
//  FileType.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//


// MARK: - Constants for file types
enum FileType {
    case video
    case image
    case other
    
    static func determine(from url: URL) -> FileType {
        let ext = url.pathExtension.lowercased()
        
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "3gp", "mpg", "mpeg"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp","jfif"]
        
        if videoExtensions.contains(ext) {
            return .video
        } else if imageExtensions.contains(ext) {
            return .image
        } else {
            return .other
        }
    }
}

class serverInfo: ObservableObject {
    @Published var serverName: String = ""
    @Published var serverPort: Int = 22
    @Published var username: String = ""
    @Published var password: String = ""
}