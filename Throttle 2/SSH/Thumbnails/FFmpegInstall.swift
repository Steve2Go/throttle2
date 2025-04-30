////
////  ServerOS.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 30/4/2025.
////
//
//
//import Foundation
//import Citadel
//import NIO
//
//// FFmpeg installer extension for ThumbnailManager
//extension ThumbnailManager {
//    
//    // Server OS detection constants
//    private enum ServerOS {
//        case linux
//        case macOS
//        case freeBSD
//        case unknown
//    }
//    
//    // Server architecture detection constants
//    private enum ServerArch {
//        case x86_64
//        case arm64
//        case i686
//        case armhf
//        case unknown
//    }
//    
//    // Cache of servers where we've installed FFmpeg
//    private static var ffmpegInstalledServers = Set<String>()
//    private static let installedServersLock = NSLock()
//    
//    // Static temp directory path for FFmpeg binaries
//    private static var ffmpegTempPath: String {
//        return "/tmp/throttle_ffmpeg_\(UUID().uuidString)"
//    }
//    
//    /**
//     Installs FFmpeg on the server if it's not already installed.
//     - parameter server: The server to install FFmpeg on
//     - returns: The path to the FFmpeg binary
//     */
//    public func ensureFFmpegInstalled(on server: ServerEntity) async throws -> String {
//        let serverKey = server.name ?? server.sftpHost ?? "default"
//        let tempDir = "/tmp/throttle_ffmpeg"
//        
//        // Check if we already installed it for this server in this session
//        Self.installedServersLock.lock()
//        let alreadyInstalled = Self.ffmpegInstalledServers.contains(serverKey)
//        Self.installedServersLock.unlock()
//        
//        if alreadyInstalled {
//            return "\(tempDir)/ffmpeg"
//        }
//        
//        // Get connection for this server
//        let connection = getConnection(for: server)
//        
//        // First check if system ffmpeg is available
//        let (statusCode, _) = try await connection.executeCommand("which ffmpeg")
//        if statusCode == 0 {
//            // FFmpeg is already available system-wide
//            return "ffmpeg"
//        }
//        
//        // Check if ffmpeg already exists in our temp directory
//        let (tempFFmpegStatus, _) = try await connection.executeCommand("[ -f \(tempDir)/ffmpeg ] && [ -x \(tempDir)/ffmpeg ] && echo 'exists'")
//        if tempFFmpegStatus == 0 {
//            // Test if the existing temp FFmpeg works
//            let (testStatus, _) = try await connection.executeCommand("\(tempDir)/ffmpeg -version")
//            if testStatus == 0 {
//                // Existing FFmpeg in temp directory is working
//                print("Using existing FFmpeg installation in \(tempDir)")
//                
//                // Mark server as having FFmpeg installed
//                Self.installedServersLock.lock()
//                Self.ffmpegInstalledServers.insert(serverKey)
//                Self.installedServersLock.unlock()
//                
//                return "\(tempDir)/ffmpeg"
//            }
//        }
//        
//        // Detect OS and architecture
//        let (os, arch) = try await detectServerSystem(using: connection)
//        
//        // Create a temp directory for FFmpeg
//        let tempDir = "/tmp/throttle_ffmpeg"
//        try await connection.executeCommand("mkdir -p \(tempDir)")
//        
//        // Install FFmpeg based on OS and architecture
//        let ffmpegPath = try await installFFmpeg(os: os, arch: arch, connection: connection, tempDir: tempDir)
//        
//        // Mark server as having FFmpeg installed
//        Self.installedServersLock.lock()
//        Self.ffmpegInstalledServers.insert(serverKey)
//        Self.installedServersLock.unlock()
//        
//        return ffmpegPath
//    }
//    
//    /**
//     Detects the server OS and architecture.
//     - parameter connection: The SSH connection to use
//     - returns: A tuple containing the detected OS and architecture
//     */
//    private func detectServerSystem(using connection: SSHConnection) async throws -> (ServerOS, ServerArch) {
//        // Detect OS
//        let (_, osOutput) = try await connection.executeCommand("uname -s")
//        let osString = osOutput.trimmingCharacters(in: .whitespacesAndNewlines)
//        
//        let os: ServerOS
//        switch osString {
//        case "Linux":
//            os = .linux
//        case "Darwin":
//            os = .macOS
//        case "FreeBSD":
//            os = .freeBSD
//        default:
//            os = .unknown
//        }
//        
//        // Detect architecture
//        let (_, archOutput) = try await connection.executeCommand("uname -m")
//        let archString = archOutput.trimmingCharacters(in: .whitespacesAndNewlines)
//        
//        let arch: ServerArch
//        switch archString {
//        case "x86_64":
//            arch = .x86_64
//        case "arm64", "aarch64":
//            arch = .arm64
//        case "i686", "i386":
//            arch = .i686
//        case "armv6l", "armv7l":
//            arch = .armhf
//        default:
//            arch = .unknown
//        }
//        
//        return (os, arch)
//    }
//    
//    /**
//     Installs FFmpeg on the server based on the detected OS and architecture.
//     - parameters:
//        - os: The server OS
//        - arch: The server architecture
//        - connection: The SSH connection to use
//        - tempDir: The temporary directory to install FFmpeg to
//     - returns: The path to the FFmpeg binary
//     */
//    private func installFFmpeg(os: ServerOS, arch: ServerArch, connection: SSHConnection, tempDir: String) async throws -> String {
//        print("Installing FFmpeg for \(os) (\(arch)) in \(tempDir)")
//        
//        // Create temp directory if it doesn't exist
//        try await connection.executeCommand("mkdir -p \(tempDir)")
//        
//        // Get download URL based on OS and architecture
//        let ffmpegURL = getFFmpegDownloadURL(os: os, arch: arch)
//        let ffprobeURL = getFFprobeDownloadURL(os: os, arch: arch)
//        
//        print("Downloading FFmpeg from \(ffmpegURL)")
//        
//        // Download FFmpeg with progress indication
//        let downloadCommand = """
//        cd \(tempDir) && \
//        echo "Downloading FFmpeg..." && \
//        if command -v curl >/dev/null 2>&1; then \
//            curl --progress-bar -L -o ffmpeg.download '\(ffmpegURL)'; \
//        else \
//            wget --progress=bar -O ffmpeg.download '\(ffmpegURL)'; \
//        fi
//        """
//        try await connection.executeCommand(downloadCommand)
//        
//        // Download FFprobe if separate
//        if !ffprobeURL.isEmpty {
//            let downloadProbeCommand = """
//            cd \(tempDir) && \
//            if command -v curl >/dev/null 2>&1; then \
//                curl -L -o ffprobe.download '\(ffprobeURL)'; \
//            else \
//                wget -O ffprobe.download '\(ffprobeURL)'; \
//            fi
//            """
//            try await connection.executeCommand(downloadProbeCommand)
//        }
//        
//        // Extract or process the downloaded files based on their format
//        if ffmpegURL.hasSuffix(".tar.xz") {
//            // Linux static build
//            try await connection.executeCommand("cd \(tempDir) && tar -xf ffmpeg.download && find . -name 'ffmpeg' -type f -exec mv {} ./ffmpeg \\; && find . -name 'ffprobe' -type f -exec mv {} ./ffprobe \\;")
//        } else if ffmpegURL.hasSuffix(".zip") {
//            // macOS build
//            try await connection.executeCommand("cd \(tempDir) && unzip -o ffmpeg.download && unzip -o ffprobe.download")
//        } else {
//            // Direct binary download
//            try await connection.executeCommand("cd \(tempDir) && mv ffmpeg.download ffmpeg && mv ffprobe.download ffprobe")
//        }
//        
//        // Make binaries executable
//        try await connection.executeCommand("chmod +x \(tempDir)/ffmpeg \(tempDir)/ffprobe")
//        
//        // Test the installation
//        let (testStatus, _) = try await connection.executeCommand("\(tempDir)/ffmpeg -version")
//        if testStatus != 0 {
//            throw NSError(domain: "FFmpegInstaller", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to install FFmpeg"])
//        }
//        
//        return "\(tempDir)/ffmpeg"
//    }
//    
//    /**
//     Gets the download URL for FFmpeg based on the server OS and architecture.
//     - parameters:
//        - os: The server OS
//        - arch: The server architecture
//     - returns: The download URL for FFmpeg
//     */
//    private func getFFmpegDownloadURL(os: ServerOS, arch: ServerArch) -> String {
//        switch os {
//        case .linux:
//            // Use johnvansickle.com static builds for Linux
//            let archName: String
//            switch arch {
//            case .x86_64:
//                archName = "amd64"
//            case .i686:
//                archName = "i686"
//            case .armhf:
//                archName = "armhf"
//            case .arm64:
//                archName = "arm64"
//            case .unknown:
//                archName = "amd64" // Default to amd64 if unknown
//            }
//            return "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-\(archName)-static.tar.xz"
//            
//        case .macOS:
//            // Use different sources for macOS based on architecture
//            if arch == .arm64 {
//                return "https://www.osxexperts.net/ffmpeg6arm.zip"
//            } else {
//                // For Intel macs, could be more complex to get the URL dynamically
//                return "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/6.0/zip"
//            }
//            
//        case .freeBSD:
//            // Use Thefrank's repo for FreeBSD
//            return "https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffmpeg"
//            
//        case .unknown:
//            // Default to Linux x86_64 if unknown
//            return "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
//        }
//    }
//    
//    /**
//     Gets the download URL for FFprobe based on the server OS and architecture.
//     - parameters:
//        - os: The server OS
//        - arch: The server architecture
//     - returns: The download URL for FFprobe, or empty string if bundled with FFmpeg
//     */
//    private func getFFprobeDownloadURL(os: ServerOS, arch: ServerArch) -> String {
//        switch os {
//        case .macOS:
//            // For macOS, FFprobe is a separate download
//            if arch == .arm64 {
//                return "https://www.osxexperts.net/ffprobe6arm.zip"
//            } else {
//                return "https://evermeet.cx/ffmpeg/getrelease/ffprobe/6.0/zip"
//            }
//            
//        case .freeBSD:
//            // For FreeBSD, FFprobe is a separate download
//            return "https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffprobe"
//            
//        default:
//            // For Linux, FFprobe is included in the FFmpeg package
//            return ""
//        }
//    }
//    
//    /**
//     Updates the generateFFmpegThumbnail method to use the installed FFmpeg binary.
//     - parameters:
//        - path: The path to the video file
//        - server: The server to generate the thumbnail on
//     - returns: The generated thumbnail image
//     */
//    public func generateFFmpegThumbnailWithFallback(for path: String, server: ServerEntity) async throws -> Image {
//        do {
//            // Try using the standard method first
//            return try await generateFFmpegThumbnail(for: path, server: server)
//        } catch let error as NSError {
//            // Check if the error is related to FFmpeg not being installed
//            if error.localizedDescription.contains("FFmpeg") || 
//               error.localizedDescription.contains("command not found") ||
//               error.localizedDescription.contains("No such file or directory") {
//                print("FFmpeg error detected: \(error.localizedDescription)")
//                
//                // Install FFmpeg
//                let ffmpegPath = try await ensureFFmpegInstalled(on: server)
//                
//                // Get reusable SSH connection for this server
//                let connection = getConnection(for: server)
//                
//                // Generate a unique temp filename on the remote server
//                let remoteTempThumbPath = "/tmp/thumb_\(UUID().uuidString).jpg"
//                
//                // Create a temporary file locally for the downloaded thumbnail
//                let tempDir = FileManager.default.temporaryDirectory
//                let localTempURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
//                
//                // Create the directory if needed
//                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
//                
//                // Create an empty file to ensure it exists
//                FileManager.default.createFile(atPath: localTempURL.path, contents: nil)
//                
//                // Clean up local temp file when done
//                defer {
//                    try? FileManager.default.removeItem(at: localTempURL)
//                }
//                
//                // Escape single quotes in paths
//                let escapedPath = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
//                let escapedThumbPath = "'\(remoteTempThumbPath.replacingOccurrences(of: "'", with: "'\\''"))'"
//                
//                let timestamps = ["00:00:06.000","00:00:02.000", "00:00:00.000"]
//                
//                for timestamp in timestamps {
//                    // Execute ffmpeg command with current timestamp, using our installed binary
//                    let ffmpegCmd = "\(ffmpegPath) -y -i \(escapedPath) -ss \(timestamp) -vframes 1 \(escapedThumbPath) 2>/dev/null || echo $?"
//                    _ = try await connection.executeCommand(ffmpegCmd)
//                    
//                    // Check if the file was created
//                    let testCmd = "[ -f \(escapedThumbPath) ] && echo 'success' || echo 'failed'"
//                    let (_, testOutput) = try await connection.executeCommand(testCmd)
//                    let testResult = testOutput.trimmingCharacters(in: .whitespacesAndNewlines)
//                    
//                    if testResult == "success" {
//                        do {
//                            // Use our improved downloadFile method to get the thumbnail
//                            try await connection.downloadFile(remotePath: remoteTempThumbPath, localURL: localTempURL) { _ in }
//                            
//                            // Clean up remote temp file
//                            let cleanupCmd = "rm -f \(escapedThumbPath)"
//                            try? await connection.executeCommand(cleanupCmd)
//                            
//                            // Load the image from the downloaded file
//                            guard let imageData = try? Data(contentsOf: localTempURL),
//                                  let uiImage = UIImage(data: imageData) else {
//                                continue // Try next timestamp if this one failed
//                            }
//                            
//                            // Check if the image is valid (not empty/black)
//                            if isEmptyImage(uiImage) {
//                                continue // Try next timestamp if this one is empty
//                            }
//                            
//                            // Cache the image
//                            memoryCache.setObject(uiImage, forKey: path as NSString)
//                            
//                            let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
//                            try? saveToCache(image: uiImage, for: path)
//                            return thumb
//                        } catch {
//                            print("Error downloading FFmpeg thumbnail: \(error)")
//                            // Continue to next timestamp if download failed
//                        }
//                    }
//                    
//                    // Clean up if this attempt failed
//                    let cleanupCmd = "rm -f \(escapedThumbPath)"
//                    try? await connection.executeCommand(cleanupCmd)
//                }
//                
//                throw NSError(domain: "ThumbnailManager", code: -3,
//                    userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail with FFmpeg"])
//            } else {
//                // If it's not an FFmpeg-related error, rethrow
//                throw error
//            }
//        }
//    }
//}
//
//// Update the getThumbnail method to use the fallback generator
//extension ThumbnailManager {
//    // Use this method to replace the video thumbnail generation in your getThumbnail method
//    public func getVideoThumbnailWithFallback(for path: String, server: ServerEntity) async throws -> Image {
//        if server.ffThumb {
//            // Use server-side FFmpeg thumbnailing if enabled
//            do {
//                return try await generateFFmpegThumbnailWithFallback(for: path, server: server)
//            } catch {
//                print("FFmpeg thumbnail failed, using default: \(error.localizedDescription)")
//                return defaultThumbnail(for: path)
//            }
//        } else {
//            // Use default for videos when server-side FFmpeg is not enabled
//            return defaultThumbnail(for: path)
//        }
//    }
//}
