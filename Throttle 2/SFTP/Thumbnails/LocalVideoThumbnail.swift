////
////  LocalVideoThumbnail.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 12/4/2025.
////
//
//
//@MainActor
//private func generateVideoThumbnail(for path: String, server: ServerEntity) async throws -> Image {
//    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//    guard let username = server.sftpUser,
//          let password = keychain["sftpPassword" + (server.name ?? "")],
//          let hostname = server.sftpHost else {
//        throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
//    }
//    
//    // Create SSH client
//    let client = try await SSHClient.connect(
//        host: hostname,
//        port: Int(server.sftpPort),
//        authenticationMethod: .passwordBased(username: username, password: password),
//        hostKeyValidator: .acceptAnything(),
//        reconnect: .never
//    )
//    
//    // Create temporary file paths
//    let temporaryDirectory = FileManager.default.temporaryDirectory
//    let tempFilePath = temporaryDirectory.appendingPathComponent("temp_video_\(UUID().uuidString).mp4")
//    let thumbPath = temporaryDirectory.appendingPathComponent("thumb_\(UUID().uuidString).jpg")
//    
//    // Define a cleanup function to ensure temp files are removed
//    let cleanup = {
//        try? FileManager.default.removeItem(at: tempFilePath)
//        try? FileManager.default.removeItem(at: thumbPath)
//    }
//    
//    // Create a named pipe instead of a regular file
//    let task = Process()
//    task.launchPath = "/usr/bin/mkfifo"
//    task.arguments = [tempFilePath.path]
//    try task.run()
//    task.waitUntilExit()
//    
//    // Create a task to start downloading the file in the background
//    let downloadTask = Task {
//        do {
//            // Open an SFTP session
//            let sftp = try await client.openSFTP()
//            
//            // Open the remote file
//            let file = try await sftp.openFile(path: path, flags: .read)
//            
//            // Create a FileHandle for the named pipe
//            let fileHandle = try FileHandle(forWritingTo: tempFilePath)
//            
//            // Read in chunks and write to the pipe
//            let chunkSize = 1024 * 1024 // 1MB chunks
//            var bytesRead = 0
//            let maxBytes = 20 * 1024 * 1024 // Only read up to 20MB
//            
//            while bytesRead < maxBytes {
//                // Read a chunk
//                let buffer = try await file.read(max: chunkSize)
//                if buffer.readableBytes == 0 { break } // End of file
//                
//                // Write to the pipe
//                fileHandle.write(Data(buffer: buffer))
//                bytesRead += buffer.readableBytes
//                
//                // If we've read at least 5MB, that's likely enough
//                if bytesRead >= 5 * 1024 * 1024 {
//                    // Check if FFmpeg has completed
//                    if FileManager.default.fileExists(atPath: thumbPath.path) {
//                        break
//                    }
//                }
//            }
//            
//            // Close the file handle (but leave the pipe open for a bit longer)
//            try fileHandle.synchronize()
//            
//            // Close the SFTP session
//            try await file.close()
//            try await sftp.close()
//        } catch {
//            print("Download error: \(error.localizedDescription)")
//        }
//    }
//    
//    // Start FFmpeg to extract a thumbnail with the -follow flag
//    let ffmpegTask = Process()
//    ffmpegTask.launchPath = "/usr/bin/env"
//    ffmpegTask.arguments = [
//        "ffmpeg",
//        "-y",
//        "-rw_timeout", "5M", // 5 second timeout
//        "-follow", "1",
//        "-i", tempFilePath.path,
//        "-frames:v", "1",
//        "-q:v", "2",
//        thumbPath.path
//    ]
//    
//    // Create a pipe for stderr output
//    let pipe = Pipe()
//    ffmpegTask.standardError = pipe
//    
//    do {
//        try ffmpegTask.run()
//        
//        // Wait for FFmpeg to complete
//        ffmpegTask.waitUntilExit()
//        
//        // Cancel the download task if it's still running
//        downloadTask.cancel()
//        
//        // Check if the thumbnail was created
//        if FileManager.default.fileExists(atPath: thumbPath.path),
//           let uiImage = UIImage(contentsOfFile: thumbPath.path) {
//            // Process the thumbnail
//            let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
//            try? saveToCache(image: uiImage, for: path)
//            
//            // Clean up
//            cleanup()
//            
//            return thumb
//        } else {
//            throw NSError(domain: "ThumbnailManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail"])
//        }
//    } catch {
//        // Clean up
//        cleanup()
//        
//        // Cancel the download task
//        downloadTask.cancel()
//        
//        throw error
//    }
//}
