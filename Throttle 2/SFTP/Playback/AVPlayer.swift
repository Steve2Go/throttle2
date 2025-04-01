//
//  VideoPlayerConfiguration.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 31/3/2025.
//


import UIKit
import AVKit
import AVFoundation
import SwiftUI

struct VideoPlayerConfiguration {
    let url: URL
    let title: String?
    let additionalUrls: [URL]?
    let startIndex: Int?
    
    init(url: URL, title: String? = nil, additionalUrls: [URL]? = nil, startIndex: Int? = nil) {
        self.url = url
        self.title = title
        self.additionalUrls = additionalUrls
        self.startIndex = startIndex
    }
}

class AVPlayerStreamViewController: UIViewController {
    // Main player view controller
    private var playerViewController: AVPlayerViewController
    private var player: AVPlayer
    
    // Stream configuration
    private var urls: [URL] = []
    private var currentIndex: Int = 0
    private var currentTitle: String?
    
    // Controls overlay
    private lazy var customControlsView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var previousButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(previousButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()
    
    private lazy var nextButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(nextButtonTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()
    
    // Player observers
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    init() {
        self.player = AVPlayer()
        self.playerViewController = AVPlayerViewController()
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        self.player = AVPlayer()
        self.playerViewController = AVPlayerViewController()
        super.init(coder: coder)
    }
    
    deinit {
        removeObservers()
    }
    
    // MARK: - View Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupPlayerViewController()
        setupCustomControls()
        setupObservers()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if isBeingDismissed || isMovingFromParent {
            player.pause()
            removeObservers()
        }
    }
    
    // MARK: - Setup
    
    private func setupPlayerViewController() {
        // Configure AVPlayerViewController
        playerViewController.player = player
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.updatesNowPlayingInfoCenter = true
        
        // Add as child view controller
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.leftAnchor.constraint(equalTo: view.leftAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerViewController.view.rightAnchor.constraint(equalTo: view.rightAnchor)
        ])
        
        playerViewController.didMove(toParent: self)
    }
    
    private func setupCustomControls() {
        view.addSubview(customControlsView)
        customControlsView.addSubview(titleLabel)
        customControlsView.addSubview(previousButton)
        customControlsView.addSubview(nextButton)
        
        NSLayoutConstraint.activate([
            customControlsView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            customControlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            customControlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            customControlsView.heightAnchor.constraint(equalToConstant: 50),
            
            titleLabel.centerYAnchor.constraint(equalTo: customControlsView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: customControlsView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            
            previousButton.centerYAnchor.constraint(equalTo: customControlsView.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -16),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),
            
            nextButton.centerYAnchor.constraint(equalTo: customControlsView.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: customControlsView.trailingAnchor, constant: -16),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupObservers() {
        // Observe playback time
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
        
        // Observe when item finishes playing
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    private func removeObservers() {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    // MARK: - Player Control
    
    func configure(with configuration: VideoPlayerConfiguration) {
        // Set up player with provided URL
        if let additionalUrls = configuration.additionalUrls, !additionalUrls.isEmpty {
            // Handle playlist
            var allUrls = [configuration.url]
            allUrls.append(contentsOf: additionalUrls)
            self.urls = allUrls
            self.currentIndex = configuration.startIndex ?? 0
            
            // Show playlist controls
            previousButton.isHidden = false
            nextButton.isHidden = false
            updateNavigationButtonsState()
        } else {
            // Single video
            self.urls = [configuration.url]
            self.currentIndex = 0
            
            // Hide playlist controls
            previousButton.isHidden = true
            nextButton.isHidden = true
        }
        
        // Set title if provided
        self.currentTitle = configuration.title
        if let title = configuration.title {
            titleLabel.text = title
            customControlsView.isHidden = false
        } else {
            customControlsView.isHidden = true
        }
        
        // Start playback
        playCurrentVideo()
    }
    
    private func playCurrentVideo() {
        guard currentIndex < urls.count else { return }
        
        // Create a new player item
        let url = urls[currentIndex]
        let playerItem = AVPlayerItem(url: url)
        
        // Replace current item
        player.replaceCurrentItem(with: playerItem)
        player.play()
        
        // Update UI
        updateNavigationButtonsState()
        updateNowPlayingInfo()
    }
    
    private func updateNavigationButtonsState() {
        previousButton.isEnabled = currentIndex > 0
        previousButton.alpha = currentIndex > 0 ? 1.0 : 0.5
        
        nextButton.isEnabled = currentIndex < urls.count - 1
        nextButton.alpha = currentIndex < urls.count - 1 ? 1.0 : 0.5
    }
    
    private func updateNowPlayingInfo() {
        // Update now playing info for Control Center
        if let currentItem = player.currentItem {
            var nowPlayingInfo = [String: Any]()
            
            nowPlayingInfo[MPMediaItemPropertyTitle] = currentTitle ?? "Video Stream"
            
            if let image = UIImage(named: "videoThumbnail") {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in return image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
            
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentItem.currentTime().seconds
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
            
            if let duration = currentItem.asset.duration.seconds, !duration.isNaN {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            }
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    // MARK: - Actions
    
    @objc private func previousButtonTapped() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        playCurrentVideo()
    }
    
    @objc private func nextButtonTapped() {
        guard currentIndex < urls.count - 1 else { return }
        currentIndex += 1
        playCurrentVideo()
    }
    
    @objc private func playerItemDidReachEnd(notification: Notification) {
        if currentIndex < urls.count - 1 {
            // Auto-advance to next video if available
            DispatchQueue.main.async {
                self.currentIndex += 1
                self.playCurrentVideo()
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct AVPlayerStreamViewControllerRepresentable: UIViewControllerRepresentable {
    let configuration: VideoPlayerConfiguration
    
    func makeUIViewController(context: Context) -> AVPlayerStreamViewController {
        let viewController = AVPlayerStreamViewController()
        viewController.configure(with: configuration)
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerStreamViewController, context: Context) {
        // Updates if needed
    }
}

// Usage example in SwiftUI
struct StreamPlayerView: View {
    let configuration: VideoPlayerConfiguration
    
    var body: some View {
        AVPlayerStreamViewControllerRepresentable(configuration: configuration)
            .ignoresSafeArea(edges: .all)
    }
}