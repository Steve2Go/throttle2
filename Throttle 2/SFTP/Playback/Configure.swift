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

// VideoViewController.swift
import UIKit

class videoViewController: UIViewController {
    var playlist: [URL]?
    var item: URL?
    var index: Int?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let item = item {
            let singlePlayerVC = VideoPlayerViewController()
            singlePlayerVC.configure(with: item)
            
            // Add to view hierarchy
            addChild(singlePlayerVC)
            view.addSubview(singlePlayerVC.view)
            singlePlayerVC.view.frame = view.bounds
            singlePlayerVC.didMove(toParent: self)
        }
        else if let playlist = playlist, playlist.count > 0 {
            let multiPlayerVC = VideoPlayerViewController()
            multiPlayerVC.configure(with: playlist, startingIndex: index ?? 0)
            
            // Add to view hierarchy
            addChild(multiPlayerVC)
            view.addSubview(multiPlayerVC.view)
            multiPlayerVC.view.frame = view.bounds
            multiPlayerVC.didMove(toParent: self)
        }
    }
    
    // Convenience initializer with configuration
    convenience init(configuration: VideoPlayerConfiguration) {
        self.init()
        if let singleItem = configuration.singleItem {
            self.item = singleItem
        } else if let playlist = configuration.playlist {
            self.playlist = playlist
            self.index = configuration.startIndex
        }
    }
}
#endif
