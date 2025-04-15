//
//  for.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
#if os(iOS)

// VideoPlayerConfiguration.swift
import Foundation

// Define a simple configuration struct for video playback
struct VideoPlayerConfiguration {
    var singleItem: URL?
    var playlist: [URL]?
    var startIndex: Int?
    
    init(singleItem: URL) {
        self.singleItem = singleItem
        self.playlist = nil
        self.startIndex = nil
    }
    
    init(playlist: [URL], startIndex: Int = 0) {
        self.singleItem = nil
        self.playlist = playlist
        self.startIndex = startIndex
    }
}
#endif
