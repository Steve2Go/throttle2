import Foundation
import SwiftUI
import AVKit

class StreamConnector: ObservableObject {
    @Published var isStreaming = false
    @Published var streamURL: URL?
    @Published var streamTitle: String?
    @Published var error: String?
    @Published var loadingStatus: String?
    
    private var streamManager: FFmpegStreamManager?
    private var activeStreamId: String?
    
    // Singleton instance for app-wide access
    static let shared = StreamConnector()
    
    private init() {}
    
    /// Start streaming a file with the given path from the server
    func startStreaming(filePath: String, fileName: String, server: ServerEntity) async {
        do {
            loadingStatus = "Connecting to server..."
            
            // Generate a unique identifier for this stream
            let streamId = UUID().uuidString
            activeStreamId = streamId
            
            // Find an available local port (use a random port in the allowed range)
            let localPort = Int.random(in: 10000...65000)
            
            // Create a stream manager for this stream
            let manager = try FFmpegStreamManager(
                server: server,
                localPort: localPort,
                identifier: streamId
            )
            
            // Configure stream options (customize as needed)
            var options = FFmpegStreamOptions()
            
            // Detect file extension to set appropriate streaming options
            if filePath.lowercased().hasSuffix(".mkv") || 
               filePath.lowercased().hasSuffix(".avi") ||
               filePath.lowercased().hasSuffix(".mov") {
                // Use more compatible options for non-MP4 files
                options = FFmpegStreamOptions.highQuality()
            } else {
                // For MP4 files, use more direct streaming
                options = FFmpegStreamOptions.directHTTPStream()
            }
            
            // Store the manager
            self.streamManager = manager
            
            loadingStatus = "Starting FFmpeg stream..."
            
            // Start the stream
            try await manager.startStreaming(filePath: filePath, options: options)
            
            // Get the stream URL
            if options.format == "hls" {
                self.streamURL = manager.getHLSPlaylistURL()
            } else {
                self.streamURL = manager.getStreamURL()
            }
            
            guard self.streamURL != nil else {
                throw StreamError.streamSetupFailed
            }
            
            self.streamTitle = fileName
            self.isStreaming = true
            self.loadingStatus = nil
            
        } catch {
            self.error = "Failed to start stream: \(error.localizedDescription)"
            self.loadingStatus = nil
            stopStreaming()
        }
    }
    
    /// Stop the current stream
    func stopStreaming() {
        // Stop the manager
        if let manager = streamManager {
            manager.stop()
        }
        
        // Remove from holder if needed
        if let streamId = activeStreamId {
            TunnelManagerHolder.shared.removeTunnel(withIdentifier: "ffmpeg-stream-\(streamId)")
        }
        
        // Reset state
        streamManager = nil
        activeStreamId = nil
        streamURL = nil
        streamTitle = nil
        isStreaming = false
    }
    
    /// Create a VideoPlayerConfiguration for the current stream
    func createPlayerConfiguration() -> VideoPlayerConfiguration? {
        guard let url = streamURL, isStreaming else { return nil }
        
        return VideoPlayerConfiguration(
            url: url, 
            title: streamTitle
        )
    }
}

enum StreamError: Error {
    case streamSetupFailed
    case connectionFailed
}

// SwiftUI view to show streaming status
struct StreamStatusView: View {
    @ObservedObject var connector = StreamConnector.shared
    @State private var showPlayer = false
    
    var body: some View {
        VStack {
            if let status = connector.loadingStatus {
                ProgressView(status)
            } else if connector.isStreaming {
                Button("Watch Stream") {
                    showPlayer = true
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
                
                Button("Stop Stream") {
                    connector.stopStreaming()
                }
                .padding()
                .foregroundColor(.red)
            }
            
            if let error = connector.error {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let config = connector.createPlayerConfiguration() {
                StreamPlayerView(configuration: config)
            }
        }
    }
}

// Extension for SFTPFileBrowserViewModel to integrate streaming
extension SFTPFileBrowserViewModel {
    func openVideoWithFFmpegStream(item: FileItem, server: ServerEntity) {
        Task {
            await StreamConnector.shared.startStreaming(
                filePath: getCurrentPath() + "/" + item.name,
                fileName: item.name,
                server: server
            )
            
            // Show the player if stream is ready
            if StreamConnector.shared.isStreaming {
                if let config = StreamConnector.shared.createPlayerConfiguration() {
                    await MainActor.run {
                        self.videoPlayerConfiguration = config
                        self.showingVideoPlayer = true
                    }
                }
            }
        }
    }
    
    // Helper to get full current path
    private func getCurrentPath() -> String {
        return currentPath
    }
}