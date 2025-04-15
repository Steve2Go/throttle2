//
//  videoViewController.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 14/4/2025.
//


//
//  VideoViewController.swift
//  Throttle 2
//
#if os(iOS)
import UIKit

class videoViewController: UIViewController {
    var playlist: [URL]?
    var item: URL?
    var index: Int?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let item = item {
            let playerVC = VideoPlayerViewController()
            playerVC.configure(with: item)
            
            // Add to view hierarchy
            addChild(playerVC)
            view.addSubview(playerVC.view)
            playerVC.view.frame = view.bounds
            playerVC.didMove(toParent: self)
        }
        else if let playlist = playlist, playlist.count > 0 {
            let playerVC = VideoPlayerViewController()
            playerVC.configure(with: playlist, startingIndex: index ?? 0)
            
            // Add to view hierarchy
            addChild(playerVC)
            view.addSubview(playerVC.view)
            playerVC.view.frame = view.bounds
            playerVC.didMove(toParent: self)
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
