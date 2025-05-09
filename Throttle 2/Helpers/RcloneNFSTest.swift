//import Foundation
//
///// Simple test utility to launch `rclone serve nfs` for a given remote.
///// Usage: Set the `remoteName` below, run this file in your app or as a CLI tool.
/////
///// To mount the NFS share from Terminal (after running this):
/////   sudo mount -t nfs -o port=PORT,mountport=PORT,tcp 127.0.0.1:/ /path/to/mountpoint
///// Replace PORT with the printed port, and /path/to/mountpoint with an existing empty directory.
//
//let remoteName = "YOUR_REMOTE_NAME" // <-- Set this to your rclone remote name
//let rclonePath = "/usr/local/bin/rclone" // Adjust if rclone is elsewhere
//
//var args = ["serve", "nfs", "\(remoteName):", "--vfs-cache-mode=full"]
//// No --addr means random port on 127.0.0.1
//
//let process = Process()
//process.executableURL = URL(fileURLWithPath: rclonePath)
//process.arguments = args
//
//let pipe = Pipe()
//process.standardOutput = pipe
//process.standardError = pipe
//
//do {
//    try process.run()
//    print("Started rclone serve nfs for remote \(remoteName). Waiting for output...")
//    // Read output to find the port
//    let handle = pipe.fileHandleForReading
//    var foundPort = false
//    while let line = try? handle.read(upToCount: 4096), let data = line, !data.isEmpty {
//        if let output = String(data: data, encoding: .utf8) {
//            print(output)
//            if let match = output.range(of: "listening on [^:]+:(\\d+)", options: .regularExpression) {
//                let portString = output[match].split(separator: ":").last
//                if let port = portString.flatMap({ Int($0) }) {
//                    print("\nNFS is being served on port \(port)")
//                    print("To mount: sudo mount -t nfs -o port=\(port),mountport=\(port),tcp 127.0.0.1:/ /path/to/mountpoint")
//                    foundPort = true
//                }
//            }
//        }
//        if foundPort { break }
//    }
//    print("rclone NFS server is running. Press Ctrl+C to stop.")
//    // Keep the process running
//    process.waitUntilExit()
//} catch {
//    print("Failed to start rclone: \(error)")
//} 
