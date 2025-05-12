#if os(iOS)
import SwiftUI
import MobileVLCKit
import UIKit
import AVFoundation

struct VLCMusicPlayer: View {
    @StateObject private var viewModel: VLCMusicPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var externalWindow: UIWindow? = nil
    
    init(urls: [URL], startIndex: Int = 0) {
        _viewModel = StateObject(wrappedValue: VLCMusicPlayerViewModel(urls: urls, startIndex: startIndex))
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 16) {
                Spacer().frame(height: 10) // Extra top padding
                // Album art
                if let artwork = viewModel.currentArtwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 240)
                        .cornerRadius(12)
                        .shadow(radius: 8)
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .foregroundColor(.gray)
                }
                // Track title
                VStack(spacing: 2) {
                    Text(viewModel.currentTitle)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if let artist = viewModel.trackArtists[viewModel.queue[safe: viewModel.currentIndex] ?? URL(fileURLWithPath: "")], !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                // Playback controls
                HStack(spacing: 40) {
                    Button(action: { viewModel.previous() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                    }
                    Button(action: { viewModel.togglePlayPause() }) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 40))
                    }
                    Button(action: { viewModel.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                    }
                }
                .padding(.vertical)
                // Progress bar
                VStack {
                    Slider(value: $viewModel.progress, in: 0...1, onEditingChanged: { editing in
                        viewModel.sliderEditingChanged(editing)
                    })
                    HStack {
                        Text(viewModel.currentTimeString)
                            .font(.caption)
                        Spacer()
                        Text(viewModel.totalTimeString)
                            .font(.caption)
                    }
                }.padding(.horizontal)
                // Queue/playlist
                HStack {
                    Text("Queue")
                        .font(.headline)
                    Spacer()
                    Button(action: { viewModel.shuffleQueue() }) {
                        Image(systemName: "shuffle")
                            .font(.title2)
                            .foregroundColor(viewModel.isShuffled ? .blue : .primary)
                    }
                }.padding([.horizontal, .top])
                List {
                    ForEach(viewModel.queue.indices, id: \..self) { idx in
                        let url = viewModel.queue[idx]
                        let title = viewModel.trackTitles[url] ?? url.lastPathComponent
                        let artist = viewModel.trackArtists[url] ?? ""
                        HStack(alignment: .center, spacing: 8) {
                            if idx == viewModel.currentIndex {
                                Image(systemName: "play.circle.fill")
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .lineLimit(1)
                                if !artist.isEmpty {
                                    Text(artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if idx != viewModel.currentIndex {
                                Button(action: { viewModel.play(at: idx) }) {
                                    Image(systemName: "arrowtriangle.right")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .onMove(perform: viewModel.move)
                }
                .environment(\..editMode, .constant(.active))
            }
            .padding()
            .background(Color(.black).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .onAppear {
                viewModel.resetPlayer()
                viewModel.start()
                setupExternalDisplay()
            }
            .onDisappear {
                viewModel.stop()
                tearDownExternalDisplay()
            }
            // Xmark close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(16)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Circle())
            }
            .padding(.top, 20)
            .padding(.trailing, 16)
        }
    }
    
    private func setupExternalDisplay() {
        guard let externalScreen = UIApplication.shared.openSessions
            .compactMap({ $0.scene as? UIWindowScene })
            .map({ $0.screen })
            .first(where: { $0 != UIScreen.main }) else { return }
        let windowScene = UIApplication.shared.connectedScenes.first(where: { scene in
            guard let ws = scene as? UIWindowScene else { return false }
            return ws.screen == externalScreen
        }) as? UIWindowScene
        guard let scene = windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = externalScreen.bounds
        let hosting = UIHostingController(rootView: ExternalMusicDisplayView(artwork: viewModel.currentArtwork, title: viewModel.currentTitle))
        hosting.view.backgroundColor = UIColor.black
        window.rootViewController = hosting
        window.isHidden = false
        externalWindow = window
    }
    private func tearDownExternalDisplay() {
        externalWindow?.isHidden = true
        externalWindow = nil
    }
}

struct ExternalMusicDisplayView: View {
    let artwork: UIImage?
    let title: String
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                if let artwork = artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 400)
                        .cornerRadius(20)
                        .shadow(radius: 16)
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180, height: 180)
                        .foregroundColor(.gray)
                }
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
        }
    }
}

class VLCMusicPlayerViewModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published var queue: [URL]
    @Published var currentIndex: Int
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTimeString: String = "0:00"
    @Published var totalTimeString: String = "0:00"
    @Published var isShuffled = false
    @Published var currentTitle: String = ""
    @Published var currentArtwork: UIImage? = nil
    @Published var trackTitles: [URL: String] = [:]
    @Published var trackArtists: [URL: String] = [:]
    
    private var originalQueue: [URL]
    private var mediaPlayer: VLCMediaPlayer
    private var isSeeking = false
    
    init(urls: [URL], startIndex: Int = 0) {
        self.queue = urls
        self.originalQueue = urls
        self.currentIndex = startIndex
        self.mediaPlayer = VLCMediaPlayer()
        super.init()
        self.mediaPlayer.delegate = self
    }
    
    func start() {
        Task {
            
            playCurrent()
            await loadAllTrackTitles()
        }
    }
    func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
        isPlaying = false
    }
    func play(at idx: Int) {
        currentIndex = idx
        playCurrent()
    }
    func next() {
        guard currentIndex < queue.count - 1 else { return }
        currentIndex += 1
        playCurrent()
    }
    func previous() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        playCurrent()
    }
    func togglePlayPause() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            isPlaying = false
        } else {
            mediaPlayer.play()
            isPlaying = true
        }
    }
    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        if isShuffled { originalQueue = queue }
    }
    func shuffleQueue() {
        isShuffled.toggle()
        if isShuffled {
            queue.shuffle()
        } else {
            queue = originalQueue
        }
        currentIndex = 0
        Task {
            await loadAllTrackTitles()
            playCurrent()
        }
    }
    private func playCurrent() {
        guard currentIndex < queue.count else { return }
        let url = queue[currentIndex]
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        mediaPlayer.play()
        DispatchQueue.main.async {
            self.isPlaying = true
        }
        
        Task {
            await updateTitleAndArtwork(for: url)
        }
    }
    @MainActor
    private func updateTitleAndArtwork(for url: URL) async {
        // Default fallback
        self.currentTitle = url.lastPathComponent
        self.currentArtwork = nil
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.commonMetadata)
            var foundTitle: String? = nil
            var foundArtwork: UIImage? = nil
            var foundArtist: String? = nil
            for meta in metadata {
                if meta.commonKey?.rawValue == "title" {
                    if let value = try? await meta.load(.value) as? String {
                        foundTitle = value
                    }
                }
                if meta.commonKey?.rawValue == "artwork" {
                    if let data = try? await meta.load(.value) as? Data, let image = UIImage(data: data) {
                        foundArtwork = image
                    }
                }
                if meta.commonKey?.rawValue == "artist" {
                    if let value = try? await meta.load(.value) as? String, !value.isEmpty {
                        foundArtist = value
                    }
                }
            }
            if let title = foundTitle, !title.isEmpty {
                self.currentTitle = title
            }
            if let artwork = foundArtwork {
                self.currentArtwork = artwork
            }
            if let artist = foundArtist {
                self.trackArtists[url] = artist
            }
        } catch {
            // Ignore errors, fallback to filename and default icon
        }
    }
    func sliderEditingChanged(_ editing: Bool) {
        isSeeking = editing
        if !editing {
            let total = Double(mediaPlayer.media?.length.intValue ?? 1)
            let targetTime = Int32(progress * total)
            mediaPlayer.time = VLCTime(int: targetTime)
        }
    }
    // VLCMediaPlayerDelegate
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        guard !isSeeking else { return }
        let current = mediaPlayer.time.intValue
        let total = mediaPlayer.media?.length.intValue ?? 1
        progress = total > 0 ? Double(current) / Double(total) : 0
        currentTimeString = formatTime(ms: current)
        totalTimeString = formatTime(ms: total)
    }
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        switch mediaPlayer.state {
        case .ended, .error:
            resetPlayer()
            next()
        case .playing:
            isPlaying = true
        case .paused, .stopped:
            isPlaying = false
        default:
            break
        }
    }
    private func formatTime(ms: Int32) -> String {
        let totalSeconds = Int(ms) / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    @MainActor
    func loadAllTrackTitles() async {
        var newTitles: [URL: String] = [:]
        var newArtists: [URL: String] = [:]
        await withTaskGroup(of: (URL, String?, String?).self) { group in
            for url in queue {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    var foundTitle: String? = nil
                    var foundArtist: String? = nil
                    if let metadata = try? await asset.load(.commonMetadata) {
                        for meta in metadata {
                            if meta.commonKey?.rawValue == "title" {
                                if let value = try? await meta.load(.value) as? String, !value.isEmpty {
                                    foundTitle = value
                                }
                            }
                            if meta.commonKey?.rawValue == "artist" {
                                if let value = try? await meta.load(.value) as? String, !value.isEmpty {
                                    foundArtist = value
                                }
                            }
                        }
                    }
                    return (url, foundTitle, foundArtist)
                }
            }
            for await (url, title, artist) in group {
                newTitles[url] = title
                newArtists[url] = artist
            }
        }
        self.trackTitles = newTitles
        self.trackArtists = newArtists
    }
    func resetPlayer() {
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer.delegate = self
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
#endif 
