//
//  ImageBrowserView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
#if os(iOS)
import SwiftUI

// MARK: - Image Browser View
struct ImageBrowserView: View {
    let imageUrls: [URL]
    @State private var currentIndex: Int
    @State private var isAnimating: Bool = false
    @State private var loadedImageIndices = Set<Int>()
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
                TabView(selection: $currentIndex) {
                    ForEach(0..<imageUrls.count, id: \.self) { index in
                        AsyncSFTPImageView(
                            url: imageUrls[index],
                            sftpConnection: sftpConnection,
                            isPreloaded: loadedImageIndices.contains(index),
                            delayLoad: isAnimating
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .background(Color.black)
                .onChange(of: currentIndex) { newIndex in
                    // Mark that we're animating
                    isAnimating = true
                    
                    // Once animation completes, preload adjacent images
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isAnimating = false
                        preloadAdjacentImages(around: newIndex)
                    }
                }
                .onAppear {
                    // Initially preload the current image and adjacent ones
                    preloadAdjacentImages(around: currentIndex)
                }
                
                // Bottom toolbar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                    
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
        #else
        // macOS implementation
        VStack {
            HStack {
                Button(action: {
                    currentIndex = max(0, currentIndex - 1)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title)
                }
                .disabled(currentIndex <= 0)
                
                Spacer()
                
                Text("\(currentIndex + 1) of \(imageUrls.count)")
                
                Spacer()
                
                Button(action: {
                    currentIndex = min(imageUrls.count - 1, currentIndex + 1)
                }) {
                    Image(systemName: "chevron.right")
                        .font(.title)
                }
                .disabled(currentIndex >= imageUrls.count - 1)
            }
            .padding()
            
            AsyncSFTPImageView(
                url: imageUrls[currentIndex],
                sftpConnection: sftpConnection,
                isPreloaded: loadedImageIndices.contains(currentIndex),
                delayLoad: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: currentIndex) { newIndex in
                preloadAdjacentImages(around: newIndex)
            }
            .onAppear {
                preloadAdjacentImages(around: currentIndex)
            }
            
            HStack {
                Button(action: { dismiss() }) {
                    Text("Close")
                }
                
                Spacer()
                
                Button(action: {
                    if let currentItem = sftpConnection.items.first(where: { $0.url == imageUrls[currentIndex] }) {
                        sftpConnection.downloadFile(currentItem)
                    }
                }) {
                    Text("Download")
                }
            }
            .padding()
        }
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
    
    private func preloadAdjacentImages(around index: Int) {
        // Add current index to loaded set
        loadedImageIndices.insert(index)
        
        // Preload one image ahead and one behind for smoother swiping
        
        // works smother without
//        if index > 0 {
//            loadedImageIndices.insert(index - 1)
//        }
//
//        if index < imageUrls.count - 1 {
//            loadedImageIndices.insert(index + 1)
//        }
    }
}


struct ZoomableImageView: View {
    let url: URL
    let sftpConnection: SFTPFileBrowserViewModel
    @State private var image: Image?
    @State private var isLoading = true
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        // Only enable dragging when zoomed in
                        DragGesture()
                            .onChanged { value in
                                // Only allow dragging when zoomed in
                                if scale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                                if scale < 1.1 {
                                    withAnimation {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                scale = min(max(scale * delta, 1.0), 5.0) // Limit scale between 1.0 and 5.0
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                                if scale < 1.0 {
                                    withAnimation {
                                        scale = 1.0
                                    }
                                } else if scale > 5.0 {
                                    withAnimation {
                                        scale = 5.0
                                    }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                    }
                // Disable swiping between images when zoomed in
                    .allowsHitTesting(scale <= 1.0)
            } else if isLoading {
                ProgressView()
            } else {
                Text("Failed to load image")
                    .foregroundColor(.gray)
            }
        }
        .onAppear {
            loadImage()
        }
        
    }
    private func loadImage() {
        isLoading = true
        
        Task {
            do {
                // Use caches directory for temporary image files
                let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let localURL = cachesDirectory.appendingPathComponent(url.lastPathComponent)
                
                // Remove any existing file
                try? FileManager.default.removeItem(at: localURL)
                
                print("Downloading image from: \(url.path)")
                
                // Create a stream to the file
                guard let outputStream = OutputStream(url: localURL, append: false) else {
                    throw NSError(domain: "Image", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Failed to create output stream"])
                }
                
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
                
                // Load the image
                #if os(iOS)
                if let uiImage = UIImage(contentsOfFile: localURL.path) {
                    print("✅ Successfully loaded UIImage")
                    let finalImage = Image(uiImage: uiImage)
                    await MainActor.run {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    print("❌ Failed to create UIImage from file")
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
                #else
                if let nsImage = NSImage(contentsOfFile: localURL.path) {
                    print("✅ Successfully loaded NSImage")
                    let finalImage = Image(nsImage: nsImage)
                    await MainActor.run {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    print("❌ Failed to create NSImage from file")
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
                #endif
                
                // Clean up after loading
                try? FileManager.default.removeItem(at: localURL)
                
            } catch {
                print("❌ Failed to load image: \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - AsyncSFTPImageView
struct AsyncSFTPImageView: View {
    let url: URL
    let sftpConnection: SFTPFileBrowserViewModel
    let isPreloaded: Bool
    let delayLoad: Bool
    
    @State private var image: Image?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var shouldStartLoading = false
    
    init(url: URL, sftpConnection: SFTPFileBrowserViewModel, isPreloaded: Bool = false, delayLoad: Bool = false) {
        self.url = url
        self.sftpConnection = sftpConnection
        self.isPreloaded = isPreloaded
        self.delayLoad = delayLoad
    }
    
    var body: some View {
        ZStack {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .modifier(PinchToZoom())
            } else if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading image...")
                        .padding(.top, 8)
                        .font(.caption)
                }
            } else if let errorMessage = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                        .padding()
                    Text("Failed to load image")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                Color.black // Empty placeholder
            }
        }
        .onAppear {
            if !delayLoad {
                initializeLoading()
            } else {
                // If we're in a swipe animation, delay loading
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    initializeLoading()
                }
            }
        }
        .onChange(of: shouldStartLoading) { 
            if shouldStartLoading && image == nil && !isLoading {
                loadImage()
            }
        }
    }
    
    private func initializeLoading() {
        // If the image is already loaded or loading, do nothing
        if image != nil || isLoading {
            return
        }
        
        // Start loading
        shouldStartLoading = true
    }
    
    private func loadImage() {
        // If image is already loaded or loading, don't start again
        guard image == nil && !isLoading else { return }
        
        isLoading = true
        
        Task {
            do {
                // Use caches directory for temporary image files
                let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let localURL = cachesDirectory.appendingPathComponent(url.lastPathComponent)
                
                // Remove any existing file
                try? FileManager.default.removeItem(at: localURL)
                
                print("Downloading image from: \(url.path)")
                
                // Create a stream to the file
                guard let outputStream = OutputStream(url: localURL, append: false) else {
                    throw NSError(domain: "Image", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to create output stream"])
                }
                
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
                
                // Load the image
                #if os(iOS)
                if let uiImage = UIImage(contentsOfFile: localURL.path) {
                    print("✅ Successfully loaded UIImage for \(url.lastPathComponent)")
                    let finalImage = Image(uiImage: uiImage)
                    await MainActor.run {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    print("❌ Failed to create UIImage from file")
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = "Could not create image from downloaded file"
                    }
                }
                #else
                if let nsImage = NSImage(contentsOfFile: localURL.path) {
                    print("✅ Successfully loaded NSImage for \(url.lastPathComponent)")
                    let finalImage = Image(nsImage: nsImage)
                    await MainActor.run {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    print("❌ Failed to create NSImage from file")
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = "Could not create image from downloaded file"
                    }
                }
                #endif
                
                // Clean up after loading
                try? FileManager.default.removeItem(at: localURL)
                
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
                // MARK: - PinchToZoom
struct PinchToZoom: ViewModifier {
    #if os(iOS)
    @State var scale: CGFloat = 1.0
    @State var lastScale: CGFloat = 1.0
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let delta = value / lastScale
                        lastScale = value
                        scale *= delta
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1.0 {
                        scale = 1.0
                    } else {
                        scale = 2.0
                    }
                }
            }
    }
    #else
    // macOS doesn't need the same pinch-to-zoom implementation
    func body(content: Content) -> some View {
        content
    }
    #endif
}
#endif
