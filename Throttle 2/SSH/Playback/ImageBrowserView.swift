import SwiftUI
#if os(iOS)
import WebKit
#endif
import Citadel
#if os(macOS)
import AppKit
#endif

// Helper to resize image data to a target size (macOS/iOS)
func resizedImageData(_ data: Data, maxSize: CGSize) -> Data? {
#if os(macOS)
    guard let image = NSImage(data: data) else { return nil }
    let aspect = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1.0)
    let targetSize = CGSize(width: image.size.width * aspect, height: image.size.height * aspect)
    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
    newImage.unlockFocus()
    return newImage.tiffRepresentation
#else
    guard let image = UIImage(data: data) else { return nil }
    let aspect = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1.0)
    let targetSize = CGSize(width: image.size.width * aspect, height: image.size.height * aspect)
    UIGraphicsBeginImageContextWithOptions(targetSize, false, 0.0)
    image.draw(in: CGRect(origin: .zero, size: targetSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return resized?.pngData()
#endif
}

// MARK: - Shared Image Loading
// This class handles image loading for both regular and external viewers
class RemoteImageLoader {
    private var downloadTask: Task<Data, Error>?
    private let url: URL
    private let server: ServerEntity
    
    init(url: URL, server: ServerEntity) {
        self.url = url
        self.server = server
    }
    
    // Use ThumbnailManagerRemote for unified logic
    func loadImage(maxWidth: Int? = nil, progressHandler: ((Double) -> Void)? = nil) async throws -> Data {
        downloadTask?.cancel()
        let task = Task<Data, Error> {
            // Use the thumbnail manager for unified SSH/FFmpeg/caching logic
            let image = try await ThumbnailManagerRemote.shared.getResizedImage(for: url.path, server: server, maxWidth: maxWidth)
            #if os(iOS)
            if let data = image.jpegData(compressionQuality: 0.9) {
                return data
            } else {
                throw NSError(domain: "RemoteImageLoader", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
            }
            #elseif os(macOS)
            if let tiffData = image.tiffRepresentation {
                return tiffData
            } else {
                throw NSError(domain: "RemoteImageLoader", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
            }
            #endif
        }
        self.downloadTask = task
        do {
            return try await task.value
        } catch {
            if error is CancellationError {
                print("Image download cancelled")
            } else {
                print("❌ Failed to load image: \(error)")
            }
            throw error
        }
    }
    
    func cancel() {
        downloadTask?.cancel()
    }
    
    deinit {
        // Ensure we cancel any ongoing tasks when the loader is deallocated
        downloadTask?.cancel()
    }
}

// MARK: - Preloading Image Cache (shared across viewers)

// MARK: - A shared state object to coordinate between views
class ImageBrowserSharedState: ObservableObject {
    @Published var currentIndex: Int
    @Published var isImageLoaded = false
    @Published var isPlayingSlideshow = false
    
    // Keep track of loaded states for individual images
    private var loadedImages: Set<Int> = []
    
    init(currentIndex: Int) {
        self.currentIndex = currentIndex
    }
    
    func imageDidLoad() {
        // Mark this index as loaded
        loadedImages.insert(currentIndex)
        isImageLoaded = true
    }
    
    func imageWillChange() {
        // Only set isImageLoaded to false if the new index isn't already loaded
        if !loadedImages.contains(currentIndex) {
            isImageLoaded = false
        }
    }
    
    // Clear cache if needed (e.g., when memory pressure occurs)
    func clearLoadedImageCache() {
        loadedImages.removeAll()
    }
}

#if os(iOS)
// MARK: - iOS Image Browser Views

struct ImageBrowserView: View {
    let imageUrls: [URL]
    @State private var currentIndex: Int
    @State private var isAnimating: Bool = false
    let sftpViewModel: SFTPFileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    // Preloading state
    @State private var preloadedImages: [Int: Data] = [:]
    @State private var preloadTasks: [Int: Task<Void, Never>] = [:]
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: SFTPFileBrowserViewModel) {
        self.imageUrls = imageUrls
        self._currentIndex = State(initialValue: initialIndex)
        self.sftpViewModel = sftpConnection
    }
    
    var body: some View {
        // iOS implementation with TabView for swiping
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                HStack {
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.3))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 1)
                            )
                    }
                    .padding([.trailing], 5)
                }
                
                Spacer()
            }
            .zIndex(2) // Ensure this stays on top
            
            VStack {
                TabView(selection: $currentIndex) {
                    ForEach(0..<imageUrls.count, id: \.self) { index in
                        SSHImageViewer(
                            url: imageUrls[index],
                            server: ServerManager.shared.selectedServer ?? sftpViewModel.server,
                            preloadedData: preloadedImages[index]
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .background(Color.black)
                .onChange(of: currentIndex) {
                    isAnimating = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isAnimating = false
                        preloadAdjacentImages(currentIndex: currentIndex)
                    }
                }
                
                // Bottom toolbar
                HStack {
                    Spacer()
                    
                    Text("\(currentIndex + 1) of \(imageUrls.count)")
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        if let currentItem = imageUrls.indices.contains(currentIndex) ?
                            sftpViewModel.items.first(where: { $0.url == imageUrls[currentIndex] }) : nil {
                            sftpViewModel.downloadFile(currentItem)
                        }
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.6))
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            preloadAdjacentImages(currentIndex: currentIndex)
        }
        .onDisappear {
            // Cancel all preload tasks
            for task in preloadTasks.values { task.cancel() }
            preloadTasks.removeAll()
            preloadedImages.removeAll()
            
            // Mark all images as invisible and remove from queue
            for url in imageUrls {
                ThumbnailManagerRemote.shared.markAsInvisible(url.path)
                Task {
                    await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
                }
            }
            
            // DON'T call cleanup on the shared ViewModel - it disconnects the SSH connection
            // that the main folder browser is still using. Only clean up our own operations.
            print("🧹 Image browser cleaned up without disconnecting shared SSH connection")
        }
    }
    
    private func preloadAdjacentImages(currentIndex: Int) {
        // Preload two images ahead and two behind
        let indicesToPreload = (currentIndex-2...currentIndex+2)
            .filter { $0 >= 0 && $0 < imageUrls.count && $0 != currentIndex }

        // Cancel any previous preload task for indices not in the new set
        for (idx, task) in preloadTasks {
            if !indicesToPreload.contains(idx) {
                let url = imageUrls[idx]
                ThumbnailManagerRemote.shared.markAsInvisible(url.path)
                Task {
                    await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
                }
                task.cancel()
                preloadTasks.removeValue(forKey: idx)
            }
        }

        for idx in indicesToPreload {
            if preloadedImages[idx] != nil { continue }
            let url = imageUrls[idx]
            let server = ServerManager.shared.selectedServer ?? sftpViewModel.server
            ThumbnailManagerRemote.shared.markAsVisible(url.path)
            let task = Task {
                let loader = RemoteImageLoader(url: url, server: server)
                do {
                    let data = try await loader.loadImage()
                    await MainActor.run {
                        preloadedImages[idx] = data
                    }
                } catch {
                    // Ignore errors for preloading
                }
                // Mark as invisible and remove from queue when done
                ThumbnailManagerRemote.shared.markAsInvisible(url.path)
                Task {
                    await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
                }
            }
            preloadTasks[idx] = task
        }
    }
}

// MARK: - SSH Image Viewer (using SSH connection)
struct SSHImageViewer: View {
    let url: URL
    let server: ServerEntity
    let preloadedData: Data?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var imageData: Data?
    @State private var loader: RemoteImageLoader?
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        ZStack {
            if let imageData = imageData {
                ImageWebView(imageData: imageData)
            } else if isLoading {
                VStack {
                    ProgressView().tint(.white)
                }
            } else if let error = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                        .padding()
                    Text("Failed to load image")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .background(Color.black)
        .onAppear {
            ThumbnailManagerRemote.shared.markAsVisible(url.path)
            if let preloaded = preloadedData {
                self.imageData = preloaded
                self.isLoading = false
            } else {
                loadImage()
            }
        }
        .onDisappear {
            ThumbnailManagerRemote.shared.markAsInvisible(url.path)
            // Also remove from queue to prevent connection errors
            Task {
                await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
            }
            loader?.cancel()
            loadingTask?.cancel()
        }
    }
    
    private func loadImage() {
        isLoading = true
        errorMessage = nil
        
        // Cancel previous loading attempt if exists
        loader?.cancel()
        loadingTask?.cancel()
        
        // Create a new loader
        let imageLoader = RemoteImageLoader(
            url: url,
            server: server
        )
        loader = imageLoader
        
        // Start the loading task
        loadingTask = Task {
            do {
                let data = try await imageLoader.loadImage { progress in
                    print("Download progress: \(Int(progress * 100))%")
                }
                
                if !Task.isCancelled {
                    await MainActor.run {
                        self.imageData = data
                        self.isLoading = false
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Enhanced External Image Browser View with Preloading
struct ExternalImageBrowserView: View {
    let imageUrls: [URL]
    @ObservedObject var sharedState: ImageBrowserSharedState
    let server: ServerEntity
    @State private var fadeOpacity: Double = 1.0
    @State private var preloadedImages: [Int: Data] = [:]
    @State private var preloadTasks: [Int: Task<Void, Never>] = [:]
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Modified TabView with animation disabled (we'll handle our own animations)
            TabView(selection: $sharedState.currentIndex) {
                ForEach(0..<imageUrls.count, id: \.self) { index in
                    EnhancedExternalSSHImageViewer(
                        url: imageUrls[index],
                        server: server,
                        sharedState: sharedState,
                        preloadedImageData: preloadedImages[index],
                        fadeOpacity: index == sharedState.currentIndex ? fadeOpacity : 0.0
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide the dots
            .animation(nil, value: sharedState.currentIndex) // Disable automatic animations
            .background(Color.black)
            .onChange(of: sharedState.currentIndex) { oldValue, newValue in
                // When index changes, trigger fade transition
                withAnimation(.easeInOut(duration: 0.3)) {
                    fadeOpacity = 0.0
                }
                // After fade out completes, fade back in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        fadeOpacity = 1.0
                    }
                }
                // Preload the next AND previous images
                preloadAdjacentImages(currentIndex: newValue)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            // Start with preloading adjacent images
            preloadAdjacentImages(currentIndex: sharedState.currentIndex)
        }
        .onDisappear {
            // Cancel all preload tasks when view disappears
            for task in preloadTasks.values {
                task.cancel()
            }
            preloadTasks.removeAll()
            preloadedImages.removeAll()
            
            // Mark all images as invisible and remove from queue
            for url in imageUrls {
                ThumbnailManagerRemote.shared.markAsInvisible(url.path)
                Task {
                    await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
                }
            }
        }
    }
    
    private func preloadAdjacentImages(currentIndex: Int) {
        // Calculate which images to preload
        let indicesToPreload = calculatePreloadIndices(currentIndex: currentIndex)
        
        // Cancel any existing preload tasks that aren't needed anymore
        for (index, task) in preloadTasks {
            if !indicesToPreload.contains(index) {
                task.cancel()
                preloadTasks.removeValue(forKey: index)
            }
        }
        
        // Start preloading for indices that aren't already loaded or being loaded
        for index in indicesToPreload {
            if preloadedImages[index] == nil && preloadTasks[index] == nil {
                preloadImage(at: index)
            }
        }
    }
    
    private func calculatePreloadIndices(currentIndex: Int) -> [Int] {
        var indices = [Int]()
        
        // Always include next image
        let nextIndex = currentIndex + 1
        if nextIndex < imageUrls.count {
            indices.append(nextIndex)
        }
        
        // Add previous image
        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            indices.append(prevIndex)
        }
        
        // Add two images ahead if in slideshow mode
        if sharedState.isPlayingSlideshow {
            let nextNextIndex = currentIndex + 2
            if nextNextIndex < imageUrls.count {
                indices.append(nextNextIndex)
            } else if currentIndex + 1 >= imageUrls.count && 0 < currentIndex {
                // If at the end of the collection, preload the first item for looping
                indices.append(0)
            }
        }
        
        return indices
    }
    
    private func preloadImage(at index: Int) {
        // Don't preload if the index is out of bounds
        guard index >= 0 && index < imageUrls.count else { return }
        
        let task = Task {
            do {
                // Create loader for preloading
                let url = imageUrls[index]
                let imageLoader = RemoteImageLoader(
                    url: url,
                    server: server
                )
                
                // Load the image data
                let data = try await imageLoader.loadImage()
                
                if !Task.isCancelled {
                    await MainActor.run {
                        // Store the preloaded image data
                        preloadedImages[index] = data
                        preloadTasks.removeValue(forKey: index)
                        print("✅ Preloaded image \(index+1) of \(imageUrls.count)")
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    print("❌ Failed to preload image \(index+1): \(error.localizedDescription)")
                }
                //await MainActor.run {
                    preloadTasks.removeValue(forKey: index)
                //}
            }
        }
        
        // Store the task
        preloadTasks[index] = task
    }
}

// MARK: - Enhanced External Image Viewer with Preloading Support
struct EnhancedExternalSSHImageViewer: View {
    let url: URL
    let server: ServerEntity
    @ObservedObject var sharedState: ImageBrowserSharedState
    let preloadedImageData: Data?
    let fadeOpacity: Double
    
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var imageData: Data?
    @State private var loader: RemoteImageLoader?
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        ZStack {
            if let imageData = imageData {
                ImageWebView(imageData: imageData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onAppear {
                        // Report that image is loaded
                        sharedState.imageDidLoad()
                    }
            } else if isLoading {
                VStack {
                    ProgressView()
                        .tint(.white)
                }
                .onAppear {
                    // Make sure we mark as not loaded during loading
                    sharedState.imageWillChange()
                }
            } else if let error = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                        .padding()
                    Text("Failed to load image")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .onAppear {
                    // Mark as loaded even on error, so slideshow can continue
                    sharedState.imageDidLoad()
                }
            }
        }
        .background(Color.black)
        .onAppear {
            // Use preloaded data if available, otherwise load normally
            if let preloadedData = preloadedImageData {
                self.imageData = preloadedData
                self.isLoading = false
                sharedState.imageDidLoad()
                print("Using preloaded image data for \(url.lastPathComponent)")
            } else {
                loadImage()
            }
        }
        .onDisappear {
            // Cancel any ongoing tasks
            loader?.cancel()
            loadingTask?.cancel()
            // Remove from thumbnail queue to prevent connection errors
            Task {
                await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: url.path)
            }
        }
    }
    
    private func loadImage() {
        isLoading = true
        errorMessage = nil
        sharedState.imageWillChange()
        
        // Cancel previous loading attempt if exists
        loader?.cancel()
        loadingTask?.cancel()
        
        // Create a new loader using the specified server
        let imageLoader = RemoteImageLoader(
            url: url,
            server: server
        )
        loader = imageLoader
        
        // Start the loading task
        loadingTask = Task {
            do {
                let data = try await imageLoader.loadImage { progress in
                    print("Download progress for \(url.lastPathComponent): \(Int(progress * 100))%")
                }
                
                if !Task.isCancelled {
                    await MainActor.run {
                        self.imageData = data
                        self.isLoading = false
                        // Image is now loaded
                        sharedState.imageDidLoad()
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                        // Mark as loaded even on error, so slideshow can continue
                        sharedState.imageDidLoad()
                    }
                }
            }
        }
    }
}

// MARK: - Image Browser Control View (for external displays)
struct ImageBrowserControlView: View {
    let imageCount: Int
    @ObservedObject var sharedState: ImageBrowserSharedState
    let onDismiss: () -> Void
    let onDownload: () -> Void
    
    // Slideshow states
    @State private var slideshowCounter: Timer? = nil
    @AppStorage("imageDelay") private var slideshowInterval: Double = 3.0 // Default: 3 seconds
    @State private var remainingTime: Double = 3.0
    @State private var countdownActive = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                HStack {
                    Text("Image Browser - External Display")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 1)
                            )
                    }
                }
                .padding()
                
                Spacer()
                
                // Slideshow controls in the middle
                VStack(spacing: 20) {
                    Text("Slideshow")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    HStack(spacing: 25) {
                        Button(action: {
                            toggleSlideshow()
                        }) {
                            Image(systemName: sharedState.isPlayingSlideshow ? "pause.circle.fill" : "play.circle.fill")
                                .resizable()
                                .frame(width: 60, height: 60)
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Interval: \(String(format: "%.1f", slideshowInterval)) seconds")
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                                
                                if countdownActive {
                                    Text("(Next: \(String(format: "%.1f", remainingTime))s)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                            
                            HStack {
                                Button(action: {
                                    decreaseInterval()
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                        .foregroundColor(.white)
                                }
                                
                                Slider(
                                    value: $slideshowInterval,
                                    in: 1.0...10.0,
                                    step: 0.5
                                )
                                .accentColor(.white)
                                .frame(width: 120)
                                .onChange(of: slideshowInterval) {
                                    if sharedState.isPlayingSlideshow {
                                        resetCountdown()
                                    }
                                }
                                
                                Button(action: {
                                    increaseInterval()
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                    }
                    .padding(.vertical)
                    .padding(.horizontal, 20)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(15)
                }
                
                Spacer()
                
                // Navigation controls
                VStack {
                    Text("Image \(sharedState.currentIndex + 1) of \(imageCount)")
                        .foregroundColor(.white)
                        .padding()
                    
                    HStack(spacing: 40) {
                        Button(action: {
                            if sharedState.currentIndex > 0 {
                                sharedState.currentIndex -= 1
                                if sharedState.isPlayingSlideshow {
                                    resetCountdown()
                                }
                            }
                        }) {
                            Image(systemName: "arrow.left.circle.fill")
                                .resizable()
                                .frame(width: 50, height: 50)
                                .foregroundColor(sharedState.currentIndex > 0 ? .white : .gray)
                        }
                        .disabled(sharedState.currentIndex <= 0)
                        
                        Button(action: onDownload) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .resizable()
                                .frame(width: 50, height: 50)
                                .foregroundColor(.white)
                        }
                        
                        Button(action: {
                            if sharedState.currentIndex < imageCount - 1 {
                                sharedState.currentIndex += 1
                                if sharedState.isPlayingSlideshow {
                                    resetCountdown()
                                }
                            }
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .resizable()
                                .frame(width: 50, height: 50)
                                .foregroundColor(sharedState.currentIndex < imageCount - 1 ? .white : .gray)
                        }
                        .disabled(sharedState.currentIndex >= imageCount - 1)
                    }
                    .padding(.bottom, 30)
                }
                
                Text("Controls on this device, image shown on external display")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding()
            }
        }
        .onDisappear {
            stopSlideshow()
        }
        .onChange(of: sharedState.isImageLoaded) { oldValue, newValue in
            if newValue && sharedState.isPlayingSlideshow && !countdownActive {
                // Image just loaded and slideshow is active, start countdown
                startCountdown()
            }
        }
        .onChange(of: sharedState.currentIndex) { oldValue, newValue in
            // When index changes, wait for image to load before starting countdown again
            if sharedState.isPlayingSlideshow {
                stopCountdown()
                // Only start countdown if image is already loaded
                if sharedState.isImageLoaded {
                    startCountdown()
                }
                // Otherwise, the onChange handler for isImageLoaded will start it
            }
        }
    }
    
    // MARK: - Slideshow Functions
    
    private func toggleSlideshow() {
        sharedState.isPlayingSlideshow.toggle()
        
        if sharedState.isPlayingSlideshow {
            if sharedState.isImageLoaded {
                startCountdown()
            }
            // If image not loaded yet, the countdown will start when isImageLoaded becomes true
        } else {
            stopCountdown()
        }
    }
    
    private func startCountdown() {
        stopCountdown()
        remainingTime = slideshowInterval
        countdownActive = true
        
        slideshowCounter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            //guard let self = self else { return }
            
            if self.remainingTime > 0 {
                self.remainingTime -= 0.1
            } else {
                self.advanceSlide()
            }
        }
    }
    
    private func stopCountdown() {
        slideshowCounter?.invalidate()
        slideshowCounter = nil
        countdownActive = false
    }
    
    private func resetCountdown() {
        if sharedState.isPlayingSlideshow {
            stopCountdown()
            if sharedState.isImageLoaded {
                startCountdown()
            }
        }
    }
    
    private func stopSlideshow() {
        sharedState.isPlayingSlideshow = false
        stopCountdown()
    }
    
    private func advanceSlide() {
        if !sharedState.isImageLoaded || remainingTime > 0 {
            return // Don't advance if image is still loading or time remaining
        }
        
        // Stop the current countdown
        stopCountdown()
        
        // Advance to next slide or loop back to beginning
        if sharedState.currentIndex < imageCount - 1 {
            sharedState.currentIndex += 1
        } else {
            // Loop back to the beginning
            sharedState.currentIndex = 0
        }
        
        // Note: We don't restart the countdown here because the onChange handler
        // for currentIndex will handle that based on whether the image is loaded
    }
    
    private func increaseInterval() {
        slideshowInterval = min(10.0, slideshowInterval + 0.5)
        if sharedState.isPlayingSlideshow && countdownActive {
            resetCountdown()
        }
    }
    
    private func decreaseInterval() {
        slideshowInterval = max(1.0, slideshowInterval - 0.5)
        if sharedState.isPlayingSlideshow && countdownActive {
            resetCountdown()
        }
    }
}

// MARK: - ImageWebView
struct ImageWebView: UIViewRepresentable {
    let imageData: Data
    
    func makeUIView(context: Context) -> WKWebView {
        // Create a configuration with appropriate preferences
        let configuration = WKWebViewConfiguration()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        
        // Configure for image viewing
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 5.0
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.bounces = true
        
        // Important: Handle double-tap to zoom
        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        webView.addGestureRecognizer(doubleTapGesture)
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Convert image data to base64
        let base64String = imageData.base64EncodedString()
        
        // Try to determine mime type based on image data
        let mimeType = determineMimeType(from: imageData)
        
        // Use HTML with embedded base64 image data
        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    background-color: black;
                    width: 100%;
                    height: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    overflow: hidden;
                }
                img {
                    width: 100vw;
                    height: 100vh;
                    object-fit: contain;
                    display: block;
                    margin: auto;
                }
            </style>
        </head>
        <body>
            <img src="data:\(mimeType);base64,\(base64String)" alt="Image" />
        </body>
        </html>
        """
        
        webView.loadHTMLString(htmlString, baseURL: nil)
    }
    
    // Helper function to determine the MIME type from image data
    private func determineMimeType(from data: Data) -> String {
        let headerData = data.prefix(12)
        let headerBytes = [UInt8](headerData)
        
        // Check for common image format signatures
        if headerBytes.count >= 2 {
            // JPEG: Starts with 0xFF 0xD8
            if headerBytes[0] == 0xFF && headerBytes[1] == 0xD8 {
                return "image/jpeg"
            }
            
            // PNG: Starts with 0x89 0x50 0x4E 0x47 0x0D 0x0A 0x1A 0x0A
            if headerBytes.count >= 8 && headerBytes[0] == 0x89 && headerBytes[1] == 0x50
                && headerBytes[2] == 0x4E && headerBytes[3] == 0x47 {
                return "image/png"
            }
            
            // GIF: Starts with "GIF87a" or "GIF89a"
            if headerBytes.count >= 6 && headerBytes[0] == 0x47 && headerBytes[1] == 0x49 && headerBytes[2] == 0x46 {
                return "image/gif"
            }
            
            // WebP: Starts with "RIFF" followed by 4 bytes then "WEBP"
            if headerBytes.count >= 12 && headerBytes[0] == 0x52 && headerBytes[1] == 0x49
                && headerBytes[2] == 0x46 && headerBytes[3] == 0x46
                && headerBytes[8] == 0x57 && headerBytes[9] == 0x45
                && headerBytes[10] == 0x42 && headerBytes[11] == 0x50 {
                return "image/webp"
            }
        }
        
        // Default to JPEG if we can't determine the type
        return "image/jpeg"
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: ImageWebView
        
        init(_ parent: ImageWebView) {
            self.parent = parent
        }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            if let webView = gesture.view as? WKWebView {
                let scrollView = webView.scrollView
                //print(scrollView.zoomScale)
                if scrollView.zoomScale == scrollView.minimumZoomScale  {
                    // If zoomed out, zoom in to the tap location
                    let location = gesture.location(in: webView)
                    let zoomRect = CGRect(
                        x: location.x - 50,
                        y: location.y - 50,
                        width: 100,
                        height: 100
                    )
                    scrollView.zoom(to: zoomRect, animated: true)
                }
                //if scrollView.zoomScale > scrollView.minimumZoomScale {
                else{
                    // If zoomed in, zoom out
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                }
            
            }
        }
    }
}

// Extension to help with creating a SwiftUI image browser view controller
extension UIViewController {
    static func createImageBrowserViewController(
        imageUrls: [URL],
        initialIndex: Int,
        sftpConnection: SFTPFileBrowserViewModel
    ) -> UIViewController {
        return ImageBrowserViewController(
            imageUrls: imageUrls,
            initialIndex: initialIndex,
            sftpConnection: sftpConnection
        )
    }
}

class ImageBrowserViewController: UIViewController {
    private var imageUrls: [URL]
    private var initialIndex: Int
    private var sftpViewModel: SFTPFileBrowserViewModel
    
    private var hostingController: UIHostingController<AnyView>?
    private var externalWindow: UIWindow?
    private var isExternalDisplayActive = false
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: SFTPFileBrowserViewModel) {
        self.imageUrls = imageUrls
        self.initialIndex = initialIndex
        self.sftpViewModel = sftpConnection
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Notify the external display manager before setting up our own display
        prepareForExternalDisplay()
        
        // Check for external displays
        configureForDisplay()
    }
    
    private func configureForDisplay() {
        if let externalSession = UIApplication.shared.openSessions.first(where: { session in
            guard let windowScene = session.scene as? UIWindowScene else { return false }
            return windowScene.screen != UIScreen.main
        }) {
            // Configure for external display
            if let windowScene = externalSession.scene as? UIWindowScene {
                setupExternalDisplay(windowScene: windowScene)
                isExternalDisplayActive = true
            } else {
                setupLocalDisplay()
                isExternalDisplayActive = false
            }
        } else {
            // No external display, setup normally
            setupLocalDisplay()
            isExternalDisplayActive = false
        }
    }
    
    private func setupLocalDisplay() {
        // Create the SwiftUI view for the local display
        let imageBrowserView = ImageBrowserView(
            imageUrls: imageUrls,
            initialIndex: initialIndex,
            sftpConnection: sftpViewModel
        )
        
        // Create a host controller for the SwiftUI view
        let hostingController = UIHostingController(
            rootView: AnyView(imageBrowserView)
        )
        
        // Add the hosting controller to our view controller
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostingController.didMove(toParent: self)
        
        self.hostingController = hostingController
    }
    
    private func setupExternalDisplay(windowScene: UIWindowScene) {
        // Create a window for the external display
        externalWindow = UIWindow(windowScene: windowScene)
        externalWindow?.frame = windowScene.screen.bounds
        
        // Use a state object to share between views
        let sharedState = ImageBrowserSharedState(currentIndex: initialIndex)
        
        // Get the server from the ViewModel
        let server = ServerManager.shared.selectedServer ?? sftpViewModel.server
        
        // Create the SwiftUI view for the external display
        let imageBrowserView = ExternalImageBrowserView(
            imageUrls: imageUrls,
            sharedState: sharedState,
            server: server
        )
        
        // Create a host controller for the external display
        let externalHostingController = UIHostingController(
            rootView: AnyView(imageBrowserView)
        )
        
        // Set up the external window
        externalWindow?.rootViewController = externalHostingController
        externalWindow?.isHidden = false
        
        // Create a control view for the main display
        let controlView = ImageBrowserControlView(
            imageCount: imageUrls.count,
            sharedState: sharedState,
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            },
            onDownload: { [weak self] in
                if let self = self, self.imageUrls.indices.contains(sharedState.currentIndex) {
                    let currentUrl = self.imageUrls[sharedState.currentIndex]
                    if let currentItem = self.sftpViewModel.items.first(where: { $0.url == currentUrl }) {
                        self.sftpViewModel.downloadFile(currentItem)
                    }
                }
            }
        )
        
        // Create the hosting controller for the main display
        let localHostingController = UIHostingController(rootView: AnyView(controlView))
        
        // Add the hosting controller to our view controller
        addChild(localHostingController)
        view.addSubview(localHostingController.view)
        localHostingController.view.frame = view.bounds
        localHostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        localHostingController.didMove(toParent: self)
        
        self.hostingController = localHostingController
    }
    
    // Prepare for external display by notifying the manager
    private func prepareForExternalDisplay() {
        ExternalDisplayManager.shared.suspendForVideoPlayer()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task { await sftpViewModel.cleanup() }
    }
    
    deinit {
        // Clean up external window
        externalWindow?.isHidden = true
        externalWindow = nil
        
        // Notify the external display manager to resume normal operation
        ExternalDisplayManager.shared.resumeAfterVideoPlayer()
    }
}

#endif

// MARK: - Cross-platform Image Browser Wrapper
struct ImageBrowserViewWrapper: View {
    let imageUrls: [URL]
    let initialIndex: Int
    let sftpConnection: SFTPFileBrowserViewModel
    
    var body: some View {
        #if os(iOS)
        ImageBrowserViewRepresentable(
            imageUrls: imageUrls,
            initialIndex: initialIndex,
            sftpConnection: sftpConnection
        )
        #else
        ImageBrowserView(
            imageUrls: imageUrls,
            initialIndex: initialIndex,
            sftpConnection: sftpConnection
        )
        #endif
    }
}

#if os(iOS)
// iOS UIViewControllerRepresentable wrapper
struct ImageBrowserViewRepresentable: UIViewControllerRepresentable {
    let imageUrls: [URL]
    let initialIndex: Int
    let sftpConnection: SFTPFileBrowserViewModel
    
    func makeUIViewController(context: Context) -> UIViewController {
        // Simply return the created view controller
        return UIViewController.createImageBrowserViewController(
            imageUrls: imageUrls,
            initialIndex: initialIndex,
            sftpConnection: sftpConnection
        )
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Nothing to update
    }
}
#endif

#if os(macOS)
// MARK: - macOS Image Browser 
struct ImageBrowserView: View {
    let imageUrls: [URL]
    let initialIndex: Int
    let sftpConnection: SFTPFileBrowserViewModel
    
    @State private var currentIndex: Int
    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: SFTPFileBrowserViewModel) {
        self.imageUrls = imageUrls
        self.initialIndex = initialIndex
        self.sftpConnection = sftpConnection
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    var body: some View {
        VStack {
            // Image display area
            ZStack {
                Color.black
                
                if isLoading {
                    ProgressView("Loading...")
                        .foregroundColor(.white)
                } else if let imageData = imageData,
                          let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.white)
                    }
                } else {
                    Text("No image available")
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Navigation controls
            HStack {
                Button(action: previousImage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentIndex <= 0)
                
                Spacer()
                
                Text("\(currentIndex + 1) of \(imageUrls.count)")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: nextImage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentIndex >= imageUrls.count - 1)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle("Image Browser")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Show in Finder") {
                    openInFinder()
                }
            }
        }
        .onAppear {
            loadCurrentImage()
        }
        .onChange(of: currentIndex) { _ in
            loadCurrentImage()
        }
    }
    
    private func loadCurrentImage() {
        guard currentIndex >= 0 && currentIndex < imageUrls.count else { return }
        
        isLoading = true
        errorMessage = nil
        imageData = nil
        
        let currentUrl = imageUrls[currentIndex]
        
        Task {
            do {
                let data = try await RemoteImageLoader(url: currentUrl, server: sftpConnection.server).loadImage()
                await MainActor.run {
                    self.imageData = data
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load image: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func previousImage() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    private func nextImage() {
        if currentIndex < imageUrls.count - 1 {
            currentIndex += 1
        }
    }
    
    private func openInFinder() {
        // On macOS, we should open the FUSE-mounted path in Finder
        guard currentIndex >= 0 && currentIndex < imageUrls.count else { return }
        
        let currentUrl = imageUrls[currentIndex]
        
        // Convert SFTP path to FUSE mount path
        if let fusePath = sftpConnection.convertToFUSEPath(currentUrl.path) {
            let fileURL = URL(fileURLWithPath: fusePath)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            // Fallback: show error or copy URL to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(currentUrl.absoluteString, forType: .string)
        }
    }
}
#endif
