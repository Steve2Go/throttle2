#if os(iOS)
import UIKit
import MobileVLCKit

class VideoPlayerViewController: UIViewController {
    private lazy var mediaPlayer: VLCMediaPlayer = {
        let player = VLCMediaPlayer()
        player.delegate = self
        return player
    }()
    
    private var urls: [URL] = []
    private var currentIndex: Int = 0
    private var isControlsVisible = true
    private var controlsTimer: Timer?
    
    private var isSliderBeingTouched = false
    private var externalWindow: UIWindow?
    
    // Swipe gesture properties
    private var swipeStartTime: Date?
    private var swipeStartPoint: CGPoint?
    private let quickSwipeTimeThreshold: TimeInterval = 0.3 // seconds
    private let quickSwipeSkipAmount: Int32 = 10 // seconds
    private let longSwipeSkipAmount: Int32 = 30 // seconds
    private let minimumSwipeDistance: CGFloat = 50 // points
    
    private lazy var videoView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // Add tap gesture to show/hide controls
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewTapped))
        view.addGestureRecognizer(tapGesture)
        
        // Add swipe gestures for seeking directly on the video view
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        view.addGestureRecognizer(panGesture)
        
        return view
    }()
    
    
    
    private lazy var gestureDetectionView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // This view stays on the main screen for gesture detection when video is on external display
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewTapped))
        view.addGestureRecognizer(tapGesture)
        
        // Add swipe gestures for seeking
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        view.addGestureRecognizer(panGesture)
        
        return view
    }()
    
    private lazy var controlsView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private lazy var playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: #selector(playPauseButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private lazy var nextButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: #selector(nextButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0.5
        button.isHidden = true
        return button
    }()
    
    private lazy var previousButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: #selector(previousButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0.5
        button.isHidden = true
        return button
    }()
    
    // Seek indicator views
    private lazy var seekIndicatorView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        view.layer.cornerRadius = 40
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.alpha = 0
        return view
    }()
    
    private lazy var seekIndicatorLabel: UILabel = {
        let label = UILabel()
        label.textColor = .black
        label.font = .boldSystemFont(ofSize: 24)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var seekIndicatorImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .black
        return imageView
    }()
    
    private lazy var timeSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .gray
        slider.thumbTintColor = .white
        slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchBegan(_:)), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchEnded(_:)), for: [.touchUpInside, .touchUpOutside])
        return slider
    }()
    
    private lazy var timeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.text = "00:00 / 00:00"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    func prepareForExternalDisplay() {
            // Force a check for external displays first
            ExternalDisplayManager.shared.startMonitoring()
            
            // Notify the external display manager that the video player will take control
            ExternalDisplayManager.shared.suspendForVideoPlayer()
        }
    
    override func viewDidLoad() {
            // Notify the external display manager before setting up our own display
            prepareForExternalDisplay()
            
            super.viewDidLoad()
            print("ViewDidLoad called")
            setupUI()
        }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        print("ViewDidLayoutSubviews called")
        mediaPlayer.drawable = videoView
    }
    
    
    private func setupUI() {
        print("Setting up UI")
        view.backgroundColor = .black
        
        // Add the gesture detection view to the main view only if we're using external display
        // This will provide a fallback control surface
        
        if let externalSession = UIApplication.shared.openSessions.first(where: { session in
            guard let windowScene = session.scene as? UIWindowScene else { return false }
            return windowScene.screen != UIScreen.main
        }) {
            guard let windowScene = externalSession.scene as? UIWindowScene else {
                view.addSubview(videoView)
                NSLayoutConstraint.activate([
                    videoView.topAnchor.constraint(equalTo: view.topAnchor),
                    videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
                return
            }
            
            // Setup for external display
            let externalScreen = windowScene.screen
            externalWindow = UIWindow(windowScene: windowScene)
            externalWindow?.frame = externalScreen.bounds
            let externalVC = UIViewController()
            externalVC.view.backgroundColor = .black
            externalVC.view.addSubview(videoView)
            videoView.frame = externalVC.view.bounds
            videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            externalWindow?.rootViewController = externalVC
            externalWindow?.isHidden = false
            
            // For external display, add the gesture detection view to the main screen
            view.addSubview(gestureDetectionView)
            NSLayoutConstraint.activate([
                gestureDetectionView.topAnchor.constraint(equalTo: view.topAnchor),
                gestureDetectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                gestureDetectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                gestureDetectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            
            // When using external display, show a message on the main screen
            let infoLabel = UILabel()
            infoLabel.text = "Video playing on external display\nSwipe here to control playback"
            infoLabel.textColor = .white
            infoLabel.textAlignment = .center
            infoLabel.numberOfLines = 0
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(infoLabel)
            
            NSLayoutConstraint.activate([
                infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                infoLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        } else {
            // Standard setup for local display
            view.addSubview(videoView)
            NSLayoutConstraint.activate([
                videoView.topAnchor.constraint(equalTo: view.topAnchor),
                videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        
        // Add seek indicator view
        view.addSubview(seekIndicatorView)
        seekIndicatorView.addSubview(seekIndicatorImageView)
        seekIndicatorView.addSubview(seekIndicatorLabel)
        
        view.addSubview(controlsView)
        
        controlsView.addSubview(playPauseButton)
        view.addSubview(closeButton)
        controlsView.addSubview(previousButton)
        controlsView.addSubview(nextButton)
        controlsView.addSubview(timeSlider)
        controlsView.addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -15),
            controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlsView.heightAnchor.constraint(equalToConstant: 100),
            
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            
            playPauseButton.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),
            playPauseButton.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 20),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            
            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 20),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),
            
            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 20),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
            
            timeSlider.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            timeSlider.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 20),
            timeSlider.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -20),
            
            timeLabel.topAnchor.constraint(equalTo: timeSlider.bottomAnchor, constant: 8),
            timeLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor),
            
            // Seek indicator constraints
            seekIndicatorView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            seekIndicatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            seekIndicatorView.widthAnchor.constraint(equalToConstant: 150),
            seekIndicatorView.heightAnchor.constraint(equalToConstant: 80),
            
            seekIndicatorImageView.topAnchor.constraint(equalTo: seekIndicatorView.topAnchor, constant: 10),
            seekIndicatorImageView.centerXAnchor.constraint(equalTo: seekIndicatorView.centerXAnchor),
            seekIndicatorImageView.widthAnchor.constraint(equalToConstant: 40),
            seekIndicatorImageView.heightAnchor.constraint(equalToConstant: 30),
            
            seekIndicatorLabel.topAnchor.constraint(equalTo: seekIndicatorImageView.bottomAnchor, constant: 5),
            seekIndicatorLabel.leadingAnchor.constraint(equalTo: seekIndicatorView.leadingAnchor),
            seekIndicatorLabel.trailingAnchor.constraint(equalTo: seekIndicatorView.trailingAnchor),
            seekIndicatorLabel.bottomAnchor.constraint(equalTo: seekIndicatorView.bottomAnchor, constant: -10)
        ])
        
        startControlsTimer()
    }
    
    private func startControlsTimer() {
        // If an external display is active, don't auto-hide controls on the main device
        guard externalWindow == nil else { return }
        
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }
    private func hideControls() {
        // If an external display is active, keep the controls visible on the main device
        guard externalWindow == nil else { return }
        
        guard isControlsVisible else { return }
        isControlsVisible = false
        UIView.animate(withDuration: 0.3) {
            self.controlsView.alpha = 0
            self.closeButton.alpha = 0
        }
    }
    
    private func showControls() {
        isControlsVisible = true
        UIView.animate(withDuration: 0.3) {
            self.controlsView.alpha = 1
            self.closeButton.alpha = 1
        }
        startControlsTimer()
    }
    
    // MARK: - Swipe Gesture Handling
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            swipeStartTime = Date()
            swipeStartPoint = gesture.location(in: gesture.view)
            
        case .ended:
            guard let startPoint = swipeStartPoint, let startTime = swipeStartTime else { return }
            
            let endPoint = gesture.location(in: gesture.view)
            let xDistance = endPoint.x - startPoint.x
            
            // Only process if the swipe is primarily horizontal and meets minimum distance
            if abs(xDistance) > minimumSwipeDistance && abs(xDistance) > abs(endPoint.y - startPoint.y) {
                // Determine swipe speed/duration
                let swipeDuration = Date().timeIntervalSince(startTime)
                let isQuickSwipe = swipeDuration < quickSwipeTimeThreshold
                
                // Determine swipe direction and amount
                let isRightSwipe = xDistance > 0
                let skipAmount = isQuickSwipe ? quickSwipeSkipAmount : longSwipeSkipAmount
                
                // Skip forward or backward
                seekVideo(by: isRightSwipe ? skipAmount : -skipAmount)
            }
            
            // Reset tracking properties
            swipeStartTime = nil
            swipeStartPoint = nil
            
        default:
            break
        }
    }
    
    private func seekVideo(by seconds: Int32) {
        guard mediaPlayer.isPlaying || mediaPlayer.state == .paused else { return }
        
        // Get current time and calculate new time
        let currentTime = mediaPlayer.time.intValue
        let totalTime = mediaPlayer.media?.length.intValue ?? 0
        let newTime = max(0, min(currentTime + (seconds * 1000), totalTime))
        
        // Set new time
        mediaPlayer.time = VLCTime(int: newTime)
        
        // Update UI to show seek indicator
        showSeekIndicator(seconds: seconds)
        
        // Update time slider and label
        if totalTime > 0 {
            timeSlider.value = Float(newTime) / Float(totalTime)
        }
        timeLabel.text = formatTime(current: Int(newTime), total: Int(totalTime))
    }
    
    private func showSeekIndicator(seconds: Int32) {
        // Configure indicator based on direction
        if seconds > 0 {
            seekIndicatorImageView.image = UIImage(systemName: "forward.fill")
            seekIndicatorLabel.text = "+\(seconds)s"
        } else {
            seekIndicatorImageView.image = UIImage(systemName: "backward.fill")
            seekIndicatorLabel.text = "\(seconds)s"
        }
        
        // Show the indicator with animation
        seekIndicatorView.isHidden = false
        seekIndicatorView.alpha = 0
        
        UIView.animate(withDuration: 0.2, animations: {
            self.seekIndicatorView.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.2, delay: 0.8, options: [], animations: {
                self.seekIndicatorView.alpha = 0
            }) { _ in
                self.seekIndicatorView.isHidden = true
            }
        }
    }
    
    @objc private func videoViewTapped() {
        if isControlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }
    
    @objc private func playPauseButtonTapped() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            mediaPlayer.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        startControlsTimer()
    }
    
    @objc private func closeButtonTapped() {
        mediaPlayer.stop()
        dismiss(animated: true)
    }
    
    @objc private func sliderValueChanged(_ slider: UISlider) {
        let targetTime = VLCTime(int: Int32(slider.value * Float(mediaPlayer.media?.length.intValue ?? 0)))
        timeLabel.text = formatTime(current: Int(targetTime?.intValue ?? 0), total: Int(mediaPlayer.media?.length.intValue ?? 0))
    }
    
    @objc private func sliderTouchBegan(_ slider: UISlider) {
        isSliderBeingTouched = true
        controlsTimer?.invalidate()
    }
    
    @objc private func sliderTouchEnded(_ slider: UISlider) {
        let targetTime = VLCTime(int: Int32(slider.value * Float(mediaPlayer.media?.length.intValue ?? 0)))
        mediaPlayer.time = targetTime
        isSliderBeingTouched = false
        startControlsTimer()
    }
    
    private func formatTime(current: Int, total: Int) -> String {
        let currentMinutes = current / 60000
        let currentSeconds = (current % 60000) / 1000
        let totalMinutes = total / 60000
        let totalSeconds = (total % 60000) / 1000
        return String(format: "%02d:%02d / %02d:%02d", currentMinutes, currentSeconds, totalMinutes, totalSeconds)
    }
    
    deinit {
            print("VideoPlayerViewController is being deinitialized")
            controlsTimer?.invalidate()
            mediaPlayer.stop()
            externalWindow?.isHidden = true
            externalWindow = nil
            
            // Notify the external display manager to resume the black screen
            ExternalDisplayManager.shared.resumeAfterVideoPlayer()
        }
    
    func configure(with url: URL) {
        print("Configuring player with single URL: \(url)")
        self.urls = [url]
        self.currentIndex = 0
        previousButton.isHidden = true
        nextButton.isHidden = true
        playCurrentVideo()
    }
    
    func configure(with urls: [URL], startingIndex: Int = 0) {
        print("Configuring player with \(urls.count) URLs, starting at index \(startingIndex)")
        self.urls = urls
        self.currentIndex = min(max(0, startingIndex), urls.count - 1)
        previousButton.isHidden = urls.count <= 1
        nextButton.isHidden = urls.count <= 1
        updateNavigationButtonsState()
        playCurrentVideo()
    }
    
    private func playCurrentVideo() {
        guard currentIndex < urls.count else {
            print("Error: Current index \(currentIndex) out of bounds for urls array of count \(urls.count)")
            return
        }
        
        let url = urls[currentIndex]
        print("Playing video at index \(currentIndex): \(url)")
        
        // Create the VLC media with optimized options for HTTP streaming
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 3000,
            "audio-track-auto-select": true,
            ":sout-keep": true,
            "http-reconnect": true,          // Add reconnection capability
            "http-continuous": true,          // Continuous data reading
            "rtsp-tcp": true,                // Force TCP for rtsp
            "ipv4-timeout": 5000,            // 5 seconds for IPv4 timeout
            "sub-track-auto-select": true,   // Auto-select subtitle track if available
            "live-caching": 1000             // Reduce live caching for less latency
        ])
        
        mediaPlayer.media = media
        mediaPlayer.play()
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    }
    
    @objc private func nextButtonTapped() {
        guard currentIndex < urls.count - 1 else { return }
        currentIndex += 1
        updateNavigationButtonsState()
        playCurrentVideo()
    }
    
    @objc private func previousButtonTapped() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        updateNavigationButtonsState()
        playCurrentVideo()
    }
    
    private func updateNavigationButtonsState() {
        previousButton.alpha = currentIndex > 0 ? 1.0 : 0.5
        nextButton.alpha = currentIndex < urls.count - 1 ? 1.0 : 0.5
    }
    
    private func playNextVideo() {
        guard !urls.isEmpty && currentIndex < urls.count - 1 else { return }
        currentIndex += 1
        updateNavigationButtonsState()
        playCurrentVideo()
    }
}

extension VideoPlayerViewController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        print("Media player state changed to: \(mediaPlayer.state.rawValue)")
        
        switch mediaPlayer.state {
        case .error:
            print("Playback error occurred")
            playNextVideo()
        case .ended:
            print("Playback ended normally")
            playNextVideo()
        case .stopped:
            print("Playback stopped")
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        case .playing:
            print("Playback started")
            print("Media length: \(mediaPlayer.media?.length.intValue ?? 0)")
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        default:
            break
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        guard !isSliderBeingTouched else { return }
        
        let currentTime = mediaPlayer.time.intValue
        let totalTime = mediaPlayer.media?.length.intValue ?? 0
        
        if totalTime > 0 {
            timeSlider.value = Float(currentTime) / Float(totalTime)
        }
        
        timeLabel.text = formatTime(current: Int(currentTime), total: Int(totalTime))
    }
}


#endif
