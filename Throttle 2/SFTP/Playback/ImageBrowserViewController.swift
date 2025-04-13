//
//  ImageBrowserViewController.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 11/4/2025.
//


//
//  ImageBrowserViewController.swift
//  Throttle 2
//
//  UIKit wrapper for the ImageBrowserView that can handle external displays
//

#if os(iOS)
import UIKit
import SwiftUI
import UIKit

struct ImageBrowserViewWrapper: UIViewControllerRepresentable {
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


// A shared state object to coordinate between views
class ImageBrowserSharedState: ObservableObject {
    @Published var currentIndex: Int
    @Published var isImageLoaded = false
    @Published var isPlayingSlideshow = false
    
    init(currentIndex: Int) {
        self.currentIndex = currentIndex
    }
    
    func imageDidLoad() {
        isImageLoaded = true
    }
    
    func imageWillChange() {
        isImageLoaded = false
    }
}

// A modified version of ImageBrowserView for external display that uses shared state
struct ExternalImageBrowserView: View {
    let imageUrls: [URL]
    @ObservedObject var sharedState: ImageBrowserSharedState
    let sftpConnection: SFTPFileBrowserViewModel
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Modified TabView that observes the shared state
            TabView(selection: $sharedState.currentIndex) {
                ForEach(0..<imageUrls.count, id: \.self) { index in
                    ExternalWebViewImageViewer(
                        url: imageUrls[index],
                        sftpConnection: sftpConnection,
                        sharedState: sharedState
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .background(Color.black)
            
            // Small display indicator
            VStack {
                Spacer()
                Text("\(sharedState.currentIndex + 1) of \(imageUrls.count)")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(10)
                    .padding(.bottom, 20)
            }
        }
        .statusBar(hidden: true)
    }
}


// A simplified control view for when the main content is on the external display
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
                                .onChange(of: slideshowInterval) { _ in
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
        .onChange(of: sharedState.isImageLoaded) { newValue in
            if newValue && sharedState.isPlayingSlideshow && !countdownActive {
                // Image just loaded and slideshow is active, start countdown
                startCountdown()
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
        
        slideshowCounter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if remainingTime > 0 {
                remainingTime -= 0.1
            } else {
                advanceSlide()
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
        if sharedState.currentIndex < imageCount - 1 {
            sharedState.currentIndex += 1
            // Countdown will be restarted when image loads
        } else {
            // Loop back to the beginning
            sharedState.currentIndex = 0
            // Countdown will be restarted when image loads
        }
        
        // Reset the countdown state (will be restarted when new image loads)
        stopCountdown()
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

class ImageBrowserViewController: UIViewController {
    private var imageUrls: [URL]
    private var initialIndex: Int
    private var sftpConnection: SFTPFileBrowserViewModel
    
    private var hostingController: UIHostingController<AnyView>?
    private var externalWindow: UIWindow?
    private var isExternalDisplayActive = false
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: SFTPFileBrowserViewModel) {
        self.imageUrls = imageUrls
        self.initialIndex = initialIndex
        self.sftpConnection = sftpConnection
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
            sftpConnection: sftpConnection
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
        
        // Create the SwiftUI view for the external display
        let imageBrowserView = ExternalImageBrowserView(
            imageUrls: imageUrls,
            sharedState: sharedState,
            sftpConnection: sftpConnection
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
                    if let currentItem = self.sftpConnection.items.first(where: { $0.url == currentUrl }) {
                        self.sftpConnection.downloadFile(currentItem)
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
    
    deinit {
        // Clean up external window
        externalWindow?.isHidden = true
        externalWindow = nil
        
        // Notify the external display manager to resume normal operation
        ExternalDisplayManager.shared.resumeAfterVideoPlayer()
    }
}



struct ExternalWebViewImageViewer: View {
    let url: URL
    let sftpConnection: SFTPFileBrowserViewModel
    @ObservedObject var sharedState: ImageBrowserSharedState
    @State private var isLoading = true
    @State private var loadedImageURL: URL?
    @State private var errorMessage: String?
    @State private var imageData: Data?
    
    var body: some View {
        ZStack {
            if let imageData = imageData {
                ImageWebView(imageData: imageData)
                    .onAppear {
                        // Report that image is loaded
                        sharedState.imageDidLoad()
                    }
            } else if isLoading {
                VStack {
                    ProgressView()
                        .foregroundColor(.white)
                    Text("Loading image...")
                        .padding(.top, 8)
                        .font(.caption)
                        .foregroundColor(.white)
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
            loadImage()
        }
    }
    
    private func loadImage() {
        isLoading = true
        errorMessage = nil
        sharedState.imageWillChange()
        
        Task {
            do {
                // Use memory instead of file system
                print("Downloading image from: \(url.path)")
                
                // Create a memory buffer to hold the image data
                let outputStream = OutputStream(toMemory: ())
                outputStream.open()
                
                // Progress adapter for image download
                let progressAdapter: ((UInt64, UInt64) -> Bool) = { bytesReceived, totalBytes in
                    // Just continue the download
                    return !Task.isCancelled
                }
                
                // Download the file using the contents method
                try sftpConnection.sftpConnection.contents(
                    atPath: url.path,
                    toStream: outputStream,
                    fromPosition: 0,
                    progress: progressAdapter
                )
                
                outputStream.close()
                
                // Get the data from the output stream
                if let data = outputStream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data {
                    await MainActor.run {
                        self.imageData = data
                        self.isLoading = false
                        // Image is now loaded
                        sharedState.imageDidLoad()
                    }
                    print("✅ Image downloaded successfully to memory, size: \(data.count) bytes")
                } else {
                    throw NSError(domain: "Image", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Failed to get image data from stream"])
                }
            } catch {
                print("❌ Failed to load image: \(error)")
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
#endif
