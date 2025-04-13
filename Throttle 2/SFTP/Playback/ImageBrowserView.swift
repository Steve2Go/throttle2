//
//  WebViewImageBrowser.swift
//  Throttle 2
//
#if os(iOS)
import SwiftUI
import WebKit

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
        #if os(iOS)
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
                            sftpConnection: sftpConnection
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
        #endif
    }
}

// MARK: - WebView Image Viewer
struct WebViewImageViewer: View {
    let url: URL
    let sftpConnection: SFTPFileBrowserViewModel
    @State private var isLoading = true
    @State private var loadedImageURL: URL?
    @State private var errorMessage: String?
    @State private var imageData: Data?
    
    var body: some View {
        ZStack {
            if let imageData = imageData {
                ImageWebView(imageData: imageData)
            } else if isLoading {
                VStack {
                    ProgressView()
                        .foregroundColor(.white)
                    Text("Loading image...")
                        .padding(.top, 8)
                        .font(.caption)
                        .foregroundColor(.white)
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
    }
    
    private func loadImage() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Use memory instead of file system
                print("Downloading image from: \(url.path)")
                
                // Create a memory buffer to hold the image data
                //let imageBuffer = NSMutableData()
                
                // Create a custom output stream that writes to our buffer
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
        
        // Determine mime type (assuming JPEG for simplicity, but could be enhanced)
        let mimeType = "image/jpeg"
        
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
