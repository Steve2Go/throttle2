#if os(iOS)
import UIKit
import AVFoundation
import AVKit

class AVVideoPlayerViewController: AVPlayerViewController {
    private var urls: [URL] = []
    private var currentIndex: Int = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Enable picture-in-picture
        allowsPictureInPicturePlayback = true
        
        // Setup playlist observer if needed
        setupPlaylistObserver()
    }
    
    func configure(with url: URL) {
        print("📹 Configuring standard AVPlayer with single URL: \(url)")
        self.urls = [url]
        self.currentIndex = 0
        playCurrentVideo()
    }
    
    func configure(with urls: [URL], startingIndex: Int = 0) {
        print("📹 Configuring standard AVPlayer with \(urls.count) URLs, starting at index \(startingIndex)")
        self.urls = urls
        self.currentIndex = min(max(0, startingIndex), urls.count - 1)
        playCurrentVideo()
    }
    
    private func playCurrentVideo() {
        guard currentIndex < urls.count else { return }
        
        let url = urls[currentIndex]
        print("📹 Playing video with standard AVPlayer (\(currentIndex + 1)/\(urls.count)): \(url)")
        
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        
        // Auto-play the video
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            newPlayer.play()
        }
    }
    
    private func setupPlaylistObserver() {
        // Observer for when the current video ends
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    @objc private func playerDidFinishPlaying() {
        // Play next video if available
        if currentIndex < urls.count - 1 {
            currentIndex += 1
            playCurrentVideo()
        } else {
            print("📹 Standard AVPlayer playlist finished")
        }
    }
    
    deinit {
        print("📹 AVVideoPlayerViewController (standard) is being deinitialized")
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        player = nil
    }
}
#endif
