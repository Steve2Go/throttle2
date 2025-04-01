//
//  FFmpegStreamError.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 31/3/2025.
//


import Foundation
import Citadel
import NIOCore
import KeychainAccess

enum FFmpegStreamError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case streamSetupFailed(Error)
    case tunnelFailed(Error)
    case invalidServerConfiguration
    case streamAlreadyRunning
    case streamNotRunning
}

class FFmpegStreamManager {
    private var sshClient: SSHClient?
    private var streamProcessId: String?
    private var tunnelManager: SSHTunnelManager?
    private let server: ServerEntity
    private var localPort: Int
    private var isStreaming: Bool = false
    private var currentFilePath: String?
    
    // Unique identifier for this stream manager
    private let streamId: String
    
    init(server: ServerEntity, localPort: Int, identifier: String = UUID().uuidString) throws {
        print("FFmpegStreamManager: Initializing with ID \(identifier)")
        self.server = server
        self.localPort = localPort
        self.streamId = identifier
        
        guard server.sftpHost != nil,
              server.sftpPort != 0,
              server.sftpUser != nil else {
            throw FFmpegStreamError.invalidServerConfiguration
        }
    }
    
    deinit {
        print("FFmpegStreamManager: Deinitializing")
        stop()
    }
    
    // Start streaming a specific file
    func startStreaming(filePath: String, options: FFmpegStreamOptions = FFmpegStreamOptions()) async throws {
        guard !isStreaming else {
            throw FFmpegStreamError.streamAlreadyRunning
        }
        
        print("FFmpegStreamManager: Starting stream for \(filePath)")
        
        try await connectSSH()
        try await startFFmpegStream(filePath: filePath, options: options)
        try await setupTunnel()
        
        isStreaming = true
        currentFilePath = filePath
    }
    
    // Stop the current stream
    func stop() {
        print("FFmpegStreamManager: Stopping stream")
        
        // Stop the FFmpeg process
        if let processId = streamProcessId, let client = sshClient {
            Task {
                // Kill the FFmpeg process using the PID file
                let killCmd = "if [ -f /tmp/ffmpeg_\(processId).pid ]; then " +
                              "kill -9 $(cat /tmp/ffmpeg_\(processId).pid) 2>/dev/null; " +
                              "rm /tmp/ffmpeg_\(processId).pid; fi"
                try? await client.executeCommand(killCmd)
                
                // Clean up any temporary stream files
                let cleanupCmd = "rm -rf /tmp/stream_*"
                try? await client.executeCommand(cleanupCmd)
                
                self.streamProcessId = nil
            }
        }
        
        // Stop the SSH tunnel
        if let tunnel = tunnelManager {
            tunnel.stop()
            self.tunnelManager = nil
        }
        
        // Close SSH connection
        if let client = sshClient {
            Task {
                try? await client.close()
                self.sshClient = nil
            }
        }
        
        isStreaming = false
        currentFilePath = nil
    }
    
    // MARK: - Private Methods
    
    private func connectSSH() async throws {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            throw FFmpegStreamError.missingCredentials
        }
        
        do {
            sshClient = try await SSHClient.connect(
                host: hostname,
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            
            print("SSH connected to \(hostname):\(server.sftpPort)")
        } catch {
            throw FFmpegStreamError.connectionFailed(error)
        }
    }
    
    private func startFFmpegStream(filePath: String, options: FFmpegStreamOptions) async throws {
        guard let client = sshClient else {
            throw FFmpegStreamError.streamNotRunning
        }
        
        // Create a temporary directory for the HTTP stream
        let tempDir = "/tmp/stream_\(UUID().uuidString)"
        let mkdirCmd = "mkdir -p \(tempDir)"
        _ = try await client.executeCommand(mkdirCmd)
        
        // Escape the file path for shell command
        let escapedPath = "'\(filePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        
        // Define the FFmpeg command based on options
        let ffmpegCmd = buildFFmpegCommand(
            filePath: escapedPath,
            tempDir: tempDir,
            options: options
        )
        
        print("Starting FFmpeg with command: \(ffmpegCmd)")
        
        // Generate a process ID to track this ffmpeg instance
        let processId = UUID().uuidString
        self.streamProcessId = processId
        
        // Create a PID file to track the process
        let pidFileCmd = "echo $$ > /tmp/ffmpeg_\(processId).pid"
        
        // Execute FFmpeg in the background with the PID tracking
        let executeCmd = "(\(pidFileCmd); \(ffmpegCmd))"
        _ = try await client.executeCommand(executeCmd)
        
        // Wait a moment for FFmpeg to start
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }
    
    private func setupTunnel() async throws {
        // Create an SSH tunnel from local port to the FFmpeg HTTP server
        // The FFmpeg server is running on localhost:8080 on the remote machine
        
        do {
            let tunnelManager = try SSHTunnelManager(
                server: server,
                localPort: localPort,
                remoteHost: "localhost",
                remotePort: 8080
            )
            
            try await tunnelManager.start()
            self.tunnelManager = tunnelManager
            
            // Store the tunnel in the global holder with our unique ID
            TunnelManagerHolder.shared.storeTunnel(tunnelManager, withIdentifier: "ffmpeg-stream-\(streamId)")
            
            print("SSH tunnel established from localhost:\(localPort) to remote FFmpeg server")
        } catch {
            throw FFmpegStreamError.tunnelFailed(error)
        }
    }
    
    private func buildFFmpegCommand(filePath: String, tempDir: String, options: FFmpegStreamOptions) -> String {
        var cmd = "ffmpeg -y -i \(filePath)"
        
        // Video options
        cmd += " -c:v \(options.videoCodec)"
        cmd += " -b:v \(options.videoBitrate)"
        
        if options.scaleVideo {
            cmd += " -vf \"scale=\(options.videoWidth):\(options.videoHeight)\""
        }
        
        // Audio options
        cmd += " -c:a \(options.audioCodec)"
        cmd += " -b:a \(options.audioBitrate)"
        
        // Streaming options
        cmd += " -f \(options.format)"
        
        // HLS specific options
        if options.format == "hls" {
            cmd += " -hls_time \(options.hlsSegmentDuration)"
            cmd += " -hls_list_size \(options.hlsListSize)"
            cmd += " -hls_flags delete_segments+append_list"
            cmd += " -hls_segment_filename \"\(tempDir)/segment_%03d.ts\""
            cmd += " \(tempDir)/playlist.m3u8"
        } else {
            // HTTP stream options
            cmd += " -listen 1 -content_type \(options.mimeType)"
            cmd += " http://127.0.0.1:8080/stream"
        }
        
        // Run in background and redirect output
        cmd += " > /dev/null 2>&1 &"
        
        return cmd
    }
    
    // MARK: - Public utilities
    
    func getStreamURL() -> URL? {
        guard isStreaming else { return nil }
        return URL(string: "http://localhost:\(localPort)/stream")
    }
    
    func getHLSPlaylistURL() -> URL? {
        guard isStreaming else { return nil }
        return URL(string: "http://localhost:\(localPort)/playlist.m3u8")
    }
    
    var status: String {
        if isStreaming {
            return "Streaming \(currentFilePath ?? "unknown file") on port \(localPort)"
        } else {
            return "Not streaming"
        }
    }
}

// Options struct for FFmpeg streaming
struct FFmpegStreamOptions {
    // Video options
    var videoCodec: String = "libx264"        // H.264 for broad compatibility
    var videoBitrate: String = "1500k"        // Medium quality
    var scaleVideo: Bool = true               // Enable rescaling
    var videoWidth: Int = 1280                // Width for rescaling
    var videoHeight: Int = 720                // Height for rescaling (or -1 for auto)
    
    // Audio options
    var audioCodec: String = "aac"            // AAC for broad compatibility
    var audioBitrate: String = "128k"         // Standard audio quality
    
    // Stream format options
    var format: String = "hls"                // "hls" or "mpegts"
    var mimeType: String = "video/MP2T"       // MIME type for direct HTTP streaming
    
    // HLS specific options
    var hlsSegmentDuration: Int = 4           // Segment duration in seconds
    var hlsListSize: Int = 10                 // Number of segments in playlist
    
    // Preset constructors for common use cases
    static func lowBandwidth() -> FFmpegStreamOptions {
        var options = FFmpegStreamOptions()
        options.videoBitrate = "800k"
        options.videoWidth = 854
        options.videoHeight = 480
        options.audioBitrate = "96k"
        return options
    }
    
    static func highQuality() -> FFmpegStreamOptions {
        var options = FFmpegStreamOptions()
        options.videoBitrate = "4000k"
        options.videoWidth = 1920
        options.videoHeight = 1080
        options.audioBitrate = "192k"
        return options
    }
    
    static func directHTTPStream() -> FFmpegStreamOptions {
        var options = FFmpegStreamOptions()
        options.format = "mpegts"
        return options
    }
}