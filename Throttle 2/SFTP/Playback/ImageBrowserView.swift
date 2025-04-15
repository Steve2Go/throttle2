#if os(iOS)
import SwiftUI
import WebKit
import Citadel

// MARK: - Image Browser View
struct ImageBrowserView: View {
    let imageUrls: [URL]
    @State private var currentIndex: Int
    @State private var isAnimating: Bool = false
    let sftpConnection: SFTPFileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: SFTPFileBrowserViewModel) {
        self.imageUrls = imageUrls
        self._currentIndex = State(initialValue: initialIndex)
        self.sftpConnection = sftpConnection
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
                            .clipShape(Circle())
                    }
                    .padding([.trailing], 5)
                }
                
                Spacer()
            }
            .zIndex(2) // Ensure this stays on top
            
            VStack {
                TabView(selection: $currentIndex) {
                    ForEach(0..<imageUrls.count, id: \.self) { index in
                        WebViewImageViewer(
                            url: imageUrls[index],
                            connectionManager: sftpConnection.connectionManager
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .background(Color.black)
                .onChange(of: currentIndex) {
                    // Mark that we're animating
                    isAnimating = true
                    
                    // Once animation completes, clear animation flag
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isAnimating = false
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
                            sftpConnection.items.first(where: { $0.url == imageUrls[currentIndex] }) : nil {
                            sftpConnection.downloadFile(currentItem)
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
    }
}

// MARK: - WebView Image Viewer
struct WebViewImageViewer: View {
    let url: URL
    let connectionManager: SFTPConnectionManager
    @State private var isLoading = true
    @State private var loadedImageURL: URL?
    @State private var errorMessage: String?
    @State private var imageData: Data?
    @State private var downloadTask: Task<Void, Never>?
    
    var body: some View {
        ZStack {
            if let imageData = imageData {
                ImageWebView(imageData: imageData)
            } else if isLoading {
                VStack {
                    ProgressView().tint(.white)
                        
//                    Text("Loading image...")
//                        .padding(.top, 8)
//                        .font(.caption)
//                        .foregroundColor(.white)
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
            loadImage()
        }
        .onDisappear {
            // Cancel download if view disappears
            downloadTask?.cancel()
        }
    }
    
    private func loadImage() {
        isLoading = true
        errorMessage = nil
        
        // Cancel previous task if exists
        downloadTask?.cancel()
        
        downloadTask = Task {
            do {
                print("Downloading image from: \(url.path)")
                
                // Create a temporary file for downloading
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".img")
                
                // Clean up when done
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                
                // Progress adapter that always continues unless task is cancelled
                let progressHandler: (Double) -> Bool = { _ in return !Task.isCancelled }
                
                // Ensure connection is established
                try await connectionManager.connect()
                
                // Download the file using Citadel
                try await connectionManager.downloadFile(
                    remotePath: url.path,
                    localURL: tempURL,
                    progress: progressHandler
                )
                
                // Check if task was cancelled
                try Task.checkCancellation()
                
                // Load the data from the temp file
                let data = try Data(contentsOf: tempURL)
                
                await MainActor.run {
                    self.imageData = data
                    self.isLoading = false
                }
                print("✅ Image downloaded successfully, size: \(data.count) bytes")
            } catch {
                if error is CancellationError {
                    print("Image download cancelled")
                } else {
                    print("❌ Failed to load image: \(error)")
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
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
                    max-width: 100%;
                    max-height: 100vh;
                    object-fit: contain;
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
        var headerData = data.prefix(12)
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
                
                if scrollView.zoomScale > scrollView.minimumZoomScale {
                    // If zoomed in, zoom out
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                } else {
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
            }
        }
    }
}
#endif
