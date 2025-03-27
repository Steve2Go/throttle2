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
    
    private lazy var videoView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // Add tap gesture to show/hide controls
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewTapped))
        view.addGestureRecognizer(tapGesture)
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
    
    private var isSliderBeingTouched = false
    
    override func viewDidLoad() {
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
        
        view.addSubview(videoView)
        view.addSubview(controlsView)
        
        controlsView.addSubview(playPauseButton)
        view.addSubview(closeButton)
        controlsView.addSubview(previousButton)
        controlsView.addSubview(nextButton)
        controlsView.addSubview(timeSlider)
        controlsView.addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
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
            timeLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor)
        ])
        
        startControlsTimer()
    }
    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }
    
            private func hideControls() {
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
        
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 3000,
            "audio-track-auto-select": true,
            ":sout-keep": true
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
