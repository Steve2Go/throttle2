//
//  FileType.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
//#if os(iOS)
import SwiftUI

// MARK: - Constants for file types
enum FileType {
    case video
    case audio
    case image
    case archive
    case part
    case other
    
    static func determine(from url: URL) -> FileType {
        // Get the path without URL encoding issues
        let path = url.path
        let ext = getFileExtension(from: path)
        
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "3gp", "mpg", "mpeg","vob"]
        let audioExtensions = ["mp3", "aac", "m4a", "wav", "flac", "ogg", "opus", "wma", "alac", "aiff", "aif", "caf"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp","jfif"]
        let archiveExtensions = ["7z", "tar", "gz", "iso", "dmg", "zip", "rar", "bin"]
        
        if videoExtensions.contains(ext) {
            return .video
        } else if audioExtensions.contains(ext) {
            return .audio
        } else if imageExtensions.contains(ext) {
            return .image
        } else if archiveExtensions.contains(ext) {
                return .archive
        } else if ext == "part" {
            return .part
    }else {
            return .other
        }
    }
    
    // Helper method to reliably get file extension even with special characters
    private static func getFileExtension(from path: String) -> String {
        // Find the last dot in the path
        if let lastDotIndex = path.lastIndex(of: ".") {
            let ext = String(path[path.index(after: lastDotIndex)...])
            return ext.lowercased()
        }
        return ""
    }
}

class serverInfo: ObservableObject {
    @Published var serverName: String = ""
    @Published var serverPort: Int = 22
    @Published var username: String = ""
    @Published var password: String = ""
}
//#endif
