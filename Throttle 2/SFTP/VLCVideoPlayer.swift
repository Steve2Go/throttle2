//
//  VLCVideoPlayerViewController.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 5/3/2025.
//


import SwiftUI
import MobileVLCKit

// MARK: - Video Player View Controller
class VLCVideoPlayerViewController: UIViewController {
    private var mediaPlayer: VLCMediaPlayer?
    private var isPlaying = false
    private var transportControlsView = UIView()
    private var activityIndicator: UIActivityIndicatorView?
    private var playPauseButton: UIButton?
    private var timeSlider: UISlider?
    private var timeLabel: UILabel?
    private var controlsTimer: Timer?
    private var controlsVisible = true
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupPlayer()
        setupUI()
        
        // Add tap gesture to show/hide controls
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tapGesture)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hide navigation bar for immersive experience
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Show navigation bar again
        navigationController?.setNavigationBarHidden(false, animated: animated)
        
        // Stop playback and clean up
        mediaPlayer?.stop()
    }
    
    private func setupPlayer() {
        // Create VLC media player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.delegate = self
        mediaPlayer?.drawable = view
        
        // Set up notification for time changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timeChanged),
            name: NSNotification.Name(rawValue: VLCMediaPlayerTimeChanged),
            object: mediaPlayer
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerStateChanged),
            name: NSNotification.Name(rawValue: VLCMediaPlayerStateChanged),
            object: mediaPlayer
        )
    }
    
    private func setupUI() {
        // Create activity indicator
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator?.color = .white
        activityIndicator?.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator!)
        
        NSLayoutConstraint.activate([
            activityIndicator!.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator!.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        // Setup transport controls view
        transportControlsView = UIView()
        transportControlsView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        transportControlsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transportControlsView)
        
        NSLayoutConstraint.activate([
            transportControlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transportControlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transportControlsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            transportControlsView.heightAnchor.constraint(equalToConstant: 100)
        ])
        
        // Add close button
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        view.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Add play/pause button
        playPauseButton = UIButton(type: .system)
        playPauseButton?.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton?.tintColor = .white
        playPauseButton?.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton?.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        transportControlsView.addSubview(playPauseButton!)
        
        // Add time slider
        timeSlider = UISlider()
        timeSlider?.translatesAutoresizingMaskIntoConstraints = false
        timeSlider?.minimumTrackTintColor = .white
        timeSlider?.maximumTrackTintColor = .gray
        timeSlider?.thumbTintColor = .white
        timeSlider?.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        timeSlider?.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        transportControlsView.addSubview(timeSlider!)
        
        // Add time label
        timeLabel = UILabel()
        timeLabel?.translatesAutoresizingMaskIntoConstraints = false
        timeLabel?.textColor = .white
        timeLabel?.text = "00:00"
        timeLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        transportControlsView.addSubview(timeLabel!)
        
        NSLayoutConstraint.activate([
            playPauseButton!.centerXAnchor.constraint(equalTo: transportControlsView.centerXAnchor),
            playPauseButton!.topAnchor.constraint(equalTo: transportControlsView.topAnchor, constant: 10),
            playPauseButton!.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton!.heightAnchor.constraint(equalToConstant: 44),
            
            timeSlider!.leadingAnchor.constraint(equalTo: transportControlsView.leadingAnchor, constant: 20),
            timeSlider!.trailingAnchor.constraint(equalTo: transportControlsView.trailingAnchor, constant: -20),
            timeSlider!.topAnchor.constraint(equalTo: playPauseButton!.bottomAnchor, constant: 10),
            
            timeLabel!.centerXAnchor.constraint(equalTo: transportControlsView.centerXAnchor),
            timeLabel!.topAnchor.constraint(equalTo: timeSlider!.bottomAnchor, constant: 5)
        ])
    }
    
    // MARK: - Video Playback Methods
    
    func playVideo(from url: URL) {
        activityIndicator?.startAnimating()
        
        let media = VLCMedia(url: url)
        mediaPlayer?.media = media
        mediaPlayer?.play()
        isPlaying = true
        updatePlayPauseButton()
        
        // Show controls temporarily
        showControls()
        scheduleControlsHiding()
    }
    
    func playVideoFromSFTP(remotePath: String, server: ServerEntity) {
        activityIndicator?.startAnimating()
        
        // Create SFTP URL for VLC
        // Format: sftp://username:password@hostname:port/path
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            return
        }
        
        let port = server.sftpPort
        
        // Properly encode the password for URL
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        guard let sftpURL = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(remotePath)") else {
            print("❌ Invalid SFTP URL")
            return
        }
        
        print("Playing SFTP URL: \(sftpURL)")
        let media = VLCMedia(url: sftpURL)
        mediaPlayer?.media = media
        mediaPlayer?.play()
        isPlaying = true
        updatePlayPauseButton()
        
        // Show controls temporarily
        showControls()
        scheduleControlsHiding()
    }
    
    @objc private func togglePlayPause() {
        if isPlaying {
            mediaPlayer?.pause()
        } else {
            mediaPlayer?.play()
        }
        
        isPlaying.toggle()
        updatePlayPauseButton()
        scheduleControlsHiding()
    }
    
    @objc private func closePlayer() {
        // Stop playback and dismiss
        mediaPlayer?.stop()
        dismiss(animated: true)
    }
    
    @objc private func sliderValueChanged() {
        // Prevent auto-hiding controls while user is interacting
        invalidateControlsTimer()
    }
    
    @objc private func sliderTouchUp() {
        guard let slider = timeSlider, let player = mediaPlayer else { return }
        
        // Set position based on slider value
        let targetPosition = Float(slider.value)
        player.position = targetPosition
        
        // Re-hide controls after a delay
        scheduleControlsHiding()
    }
    
    @objc private func timeChanged(notification: Notification) {
        guard let player = mediaPlayer else { return }
        
        // Update time slider position
        timeSlider?.value = Float(player.position)
        
        // Update time label
        let currentTime = formatTime(player.time.intValue / 1000)
        let totalTime = formatTime(player.media?.length.intValue ?? 0 / 1000)
        timeLabel?.text = "\(currentTime) / \(totalTime)"
    }
    
    @objc private func mediaPlayerStateChanged(notification: Notification) {
        guard let player = mediaPlayer else { return }
        
        switch player.state {
        case .playing:
            activityIndicator?.stopAnimating()
            isPlaying = true
        case .paused:
            isPlaying = false
        case .stopped:
            isPlaying = false
        case .buffering:
            activityIndicator?.startAnimating()
        case .error:
            print("❌ VLC Player Error")
            activityIndicator?.stopAnimating()
        default:
            break
        }
        
        updatePlayPauseButton()
    }
    
    private func updatePlayPauseButton() {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton?.setImage(UIImage(systemName: imageName), for: .normal)
    }
    
    // MARK: - Controls Visibility
    
    @objc private func toggleControls() {
        if controlsVisible {
            hideControls()
        } else {
            showControls()
            scheduleControlsHiding()
        }
    }
    
    private func showControls() {
        UIView.animate(withDuration: 0.3) {
            self.transportControlsView.alpha = 1.0
        }
        controlsVisible = true
    }
    
    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.transportControlsView.alpha = 0.0
        }
        controlsVisible = false
    }
    
    private func scheduleControlsHiding() {
        invalidateControlsTimer()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }
    
    private func invalidateControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = nil
    }
    
    // MARK: - Helper Methods
    
    private func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let seconds = seconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - SwiftUI Wrapper
struct VLCVideoPlayerView: UIViewControllerRepresentable {
    let fileItem: FileItem
    let server: ServerEntity
    
    func makeUIViewController(context: Context) -> VLCVideoPlayerViewController {
        return VLCVideoPlayerViewController()
    }
    
    func updateUIViewController(_ uiViewController: VLCVideoPlayerViewController, context: Context) {
        // Play the video from SFTP
        uiViewController.playVideoFromSFTP(remotePath: fileItem.url.path, server: server)
    }
}

// MARK: - File Handler Extension
extension SFTPFileBrowserViewModel {
    // Update openFile to use in-app VLCKit player
    func openFile(item: FileItem, server: ServerEntity) {
        guard !item.isDirectory else {
            navigateToFolder(item.name)
            return
        }
        
        let fileType = FileType.determine(from: item.url)
        
        switch fileType {
        case .video:
            // For videos, check size to determine approach
            if let size = item.size, size < 50_000_000 { // < 50MB - adjust as needed
                // Download to temp and play with VLC
                downloadAndPlayVideo(item, server: server)
            } else {
                // Stream directly with SFTP URL using VLCKit player
                openVideoWithVLCKit(item: item, server: server)
            }
        case .image:
            openImageBrowser(item)
        case .other:
            downloadFile(item)
        }
    }
    
    // Method to download small videos before playing
    private func downloadAndPlayVideo(_ item: FileItem, server: ServerEntity) {
        // Show download progress
        DispatchQueue.main.async {
            self.activeDownload = item
            self.isDownloading = true
            self.downloadProgress = 0
        }
        
        // Get temporary directory for video file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
        
        // Remove existing file if needed
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        downloadTask = Task {
            do {
                // Progress handler to update UI
                let progressHandler: ((Double) -> Void) = { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                    }
                }
                
                // Download using stream-based method
                try await self.downloadFileAsync(
                    remotePath: item.url.path,
                    localURL: tempURL,
                    progressHandler: progressHandler
                )
                
                // Verify download succeeded
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    DispatchQueue.main.async {
                        self.downloadProgress = 1.0
                        self.isDownloading = false
                        self.activeDownload = nil
                        
                        // Present video player with local file
                        self.presentVideoPlayer(localURL: tempURL, item: item, server: server)
                    }
                } else {
                    throw NSError(domain: "Download", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "File not found after download"])
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Download error: \(error)")
                    self.isDownloading = false
                    self.activeDownload = nil
                }
            }
        }
    }
    
    // Method to open video directly with VLCKit
    func openVideoWithVLCKit(item: FileItem, server: ServerEntity) {
        // Present video player with SFTP URL
        presentVideoPlayer(item: item, server: server)
    }
    
    // Helper to present video player
    private func presentVideoPlayer(localURL: URL? = nil, item: FileItem, server: ServerEntity) {
        // Implementation depends on your app structure
        // This is a conceptual implementation that needs to be adapted
        
        #if os(iOS)
        let videoPlayerVC = VLCVideoPlayerViewController()
        
        // Find the active window scene
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            
            if let localURL = localURL {
                // Play from local file
                videoPlayerVC.playVideo(from: localURL)
            } else {
                // Stream from SFTP
                videoPlayerVC.playVideoFromSFTP(remotePath: item.url.path, server: server)
            }
            
            // Present fullscreen
            videoPlayerVC.modalPresentationStyle = .fullScreen
            rootVC.present(videoPlayerVC, animated: true)
        }
        #endif
    }
}