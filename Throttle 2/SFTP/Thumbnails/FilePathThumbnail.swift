//import SwiftUI
//import Kingfisher
//import AVFoundation
//
///// A simplified SwiftUI view that displays thumbnails for file paths
//public struct PathThumbnailView: View {
//    // Original API parameters
//    let path: String
//    let server: ServerEntity?
//    let fromRow: Bool?
//    
//    // Display configuration
//    private var size: CGSize {
//        return fromRow == true ? CGSize(width: 50, height: 50) : CGSize(width: 80, height: 80)
//    }
//    private var cornerRadius: CGFloat = 6
//    
//    // Computed properties for file type detection
//    private var isVideo: Bool {
//        let videoExtensions = ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm", "mpg", "mpeg"]
//        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
//        return videoExtensions.contains(fileExtension)
//    }
//    
//    private var fileType: FileType {
//        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
//        
//        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp"].contains(ext) {
//            return .image
//        } else if ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm", "mpg", "mpeg"].contains(ext) {
//            return .video
//        } else if ["mp3", "wav", "aac", "m4a", "flac", "ogg"].contains(ext) {
//            return .audio
//        } else if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf"].contains(ext) {
//            return .document
//        } else {
//            return .other
//        }
//    }
//    
//    /// Creates a new PathThumbnailView
//    /// - Parameters:
//    ///   - path: The file path
//    ///   - server: The server entity (optional)
//    ///   - fromRow: Whether this thumbnail is displayed in a row (affects sizing)
//    public init(path: String, server: ServerEntity?, fromRow: Bool?) {
//        self.path = path
//        self.server = server
//        self.fromRow = fromRow
//    }
//    
//    public var body: some View {
//        ZStack {
//            // Background with corner radius
//            RoundedRectangle(cornerRadius: cornerRadius)
//                //.fill(Color(.systemGray6))
//            
//            // Placeholder based on file type
//            Image(systemName: iconForFileType)
//                .resizable()
//                .aspectRatio(contentMode: .fit)
//                .frame(width: 50, height: 50)
//                //.foregroundColor(Color(.systemGray3))
//            
//           
//            if server != nil {
//                // Remote file - handle with URLFetcher
//                URLFetcher(path: path, server: server) { url in
//                    if self.isVideo {
//                        videoThumbnail(for: url)
//                    } else {
//                        imageThumbnail(for: url)
//                    }
//                }
//            }
//        }
//        .frame(width: size.width, height: size.height)
//    }
//    
//    // Simple image thumbnail view
//    private func imageThumbnail(for url: URL) -> some View {
//        KFImage(url)
//            .resizable()
//            .aspectRatio(contentMode: .fill)
//            .frame(width: size.width, height: size.height)
//            .clipped()
//            .cornerRadius(cornerRadius)
//    }
//    
//    // Video thumbnail with play button overlay
//    private func videoThumbnail(for url: URL) -> some View {
//        ZStack {
//            KFImage(source: .provider(AVAssetImageDataProvider(assetURL: url, seconds: 1.0)))
//                .resizable()
//                .aspectRatio(contentMode: .fill)
//                .frame(width: size.width, height: size.height)
//                .clipped()
//                .cornerRadius(cornerRadius)
//            
//            // Play button overlay
////            Image(systemName: "play.fill")
////                .foregroundColor(.white)
////                .shadow(radius: 2)
////                .frame(width: 20, height: 20)
////                .padding(5)
////                .background(Circle().fill(Color.black.opacity(0.5)))
//        }
//    }
//    
//    // Determine icon based on file type
//    private var iconForFileType: String {
//        switch fileType {
//        case .image:
//            return "photo"
//        case .video:
//            return "play.rectangle"
//        case .audio:
//            return "music.note"
//        case .document:
//            return "doc.text"
//        case .other:
//            return "doc"
//        }
//    }
//    
//    // File type enum for placeholders
//    private enum FileType {
//        case image
//        case video
//        case audio
//        case document
//        case other
//    }
//}
//
//// URL fetcher that uses WHATWG encoding for paths
//struct URLFetcher<Content: View>: View {
//    let path: String
//    let server: ServerEntity?
//    let content: (URL) -> Content
//    
//    @State private var url: URL?
//    
//    init(path: String, server: ServerEntity?, @ViewBuilder content: @escaping (URL) -> Content) {
//        self.path = path
//        self.server = server
//        self.content = content
//    }
//    
//    var body: some View {
//        Group {
//            if let url = url {
//                content(url)
//            } else {
//                Color.clear
//            }
//        }
//        .onAppear {
//            fetchURL()
//        }
//    }
//    
//    private func fetchURL() {
//        guard let server = server else { return }
//        
//        // Fixed port as in your code
//        let localPort = 8080
//        
//        // Create a cancellation timer
//        let fetchTask = Task {
//            do {
//                if let streamingURL = try await createWHATWGPathURL(
//                    for: path,
//                    server: server,
//                    localPort: localPort
//                ) {
//                    DispatchQueue.main.async {
//                        self.url = streamingURL
//                    }
//                }
//            } catch {
//                print("Error loading URL: \(error)")
//            }
//        }
//        
//        // Simple 3-second timeout
//        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
//            fetchTask.cancel()
//        }
//    }
//    
//    /// Create a streaming URL with WHATWG-compliant path encoding
//    /// Uses HttpStreamingManager for username and password, but handles path encoding directly
//    private func createWHATWGPathURL(
//        for filePath: String,
//        server: ServerEntity,
//        localPort: Int,
//        forceRefresh: Bool = false
//    ) async throws -> URL? {
//        // Get the URL from the HttpStreamingManager as a starting point
//        guard let baseURL = try await HttpStreamingManager.shared.createStreamingURL(
//            for: filePath,
//            server: server,
//            localPort: localPort,
//            forceRefresh: forceRefresh
//        ) else {
//            return nil
//        }
//        
//        // We'll use the components from the baseURL but re-encode the path with WHATWG
//        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
//            return baseURL // Fall back to original URL if we can't parse it
//        }
//        
//        // Get the path from the original URL
//        let path = components.path
//        
//        // Create a custom path with WHATWG encoding
//        let whatwgPath = encodePath(path)
//        
//        // Update components with the WHATWG encoded path
//        components.path = whatwgPath
//        
//        // Return the new URL with WHATWG path encoding or the original as fallback
//        return components.url ?? baseURL
//    }
//    
//    /// Encode a path string following WHATWG path encoding rules
//    private func encodePath(_ path: String) -> String {
//        // Special set of characters allowed in URL paths according to WHATWG
//        // This is more permissive than Swift's default URLPathAllowedCharacterSet
//        var allowedInPath = CharacterSet.urlPathAllowed
//        
//        // Remove characters that should be encoded in paths according to WHATWG
//        // These are characters with special meaning in URLs or problematic in some contexts
//        allowedInPath.remove(charactersIn: "[]{}|\\^<>`\"#?&=+%@")
//        
//        // WHATWG specifies that spaces should be encoded as %20 (not +)
//        allowedInPath.remove(charactersIn: " ")
//        
//        // Split path by segments to preserve / characters
//        let pathSegments = path.split(separator: "/")
//        
//        // Encode each segment separately
//        let encodedSegments = pathSegments.map { segment in
//            return segment.addingPercentEncoding(withAllowedCharacters: allowedInPath) ?? String(segment)
//        }
//        
//        // Rebuild the path with / separators
//        var result = ""
//        if path.hasPrefix("/") {
//            result = "/"
//        }
//        
//        result += encodedSegments.joined(separator: "/")
//        
//        if path.hasSuffix("/") {
//            result += "/"
//        }
//        
//        return result
//    }
//}
