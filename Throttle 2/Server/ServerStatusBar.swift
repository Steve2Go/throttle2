import SwiftUI

struct ServerStatusBar: View {
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    @Binding var showServerSettings: Bool
    @AppStorage("filterdCount") var filterdCount: Int = 0
    @AppStorage("downloadDir") var downloadDir: String = ""
    
    // Stats state
    @State private var downloadSpeed: Int64 = 0
    @State private var uploadSpeed: Int64 = 0
    @State private var activeTorrents: Int = 0
    @State private var totalTorrents: Int = 0
    @State private var freeSpace: Int64 = 0
    @State private var refreshTask: Task<Void, Never>?
//    @AppStorage("isMounted") var isMounted: Bool = false
    
    // Timer for refresh
    @State private var timer: Timer?
    @State private var ftpServerCount: Int = 0
    @State private var ftpStatusTimer: Timer? = nil
    
    // Computed properties for formatted values
    private var downloadSpeedFormatted: String {
        formatBytes(downloadSpeed) + "s"
    }
    
    private var uploadSpeedFormatted: String {
        formatBytes(uploadSpeed) + "s"
    }
    
    private var freeSpaceFormatted: String {
        formatBytes(freeSpace)
    }
    
#if os(iOS)
var isiPad: Bool {
    return UIDevice.current.userInterfaceIdiom == .pad
}
#endif
    
    var body: some View {
        // Define scaling factors based on platform
        var scale: CGFloat = 1.0
        
        let spacing: CGFloat = 12
        let innerSpacing: CGFloat = 4
        var horizontalPadding: CGFloat = 16
        var verticalPadding: CGFloat = 6
        
        #if os(iOS)
        if !isiPad {
            scale = 0.75
        }
        horizontalPadding = -60.0
        verticalPadding = 0
        #else
        scale = 0.9
        horizontalPadding = -30.0
        #endif
        
        return HStack(spacing: spacing) {
            if store.selection == nil {
                Text("No server selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            } else {
                Spacer()
                
                VStack(alignment:.leading) {
                    HStack{
                        Text("↓").font(.caption).foregroundColor(.blue)
                        Text("\(downloadSpeedFormatted)").font(.caption)
                    }
                    HStack {
                        HStack{
                            Text("↑").font(.caption).foregroundColor(.green)
                            Text("\(uploadSpeedFormatted)").font(.caption)
                        }
                    }
                }
                Spacer()
                //                Divider()
                //                    .frame(height: dividerHeight)
                //tunnels
                HStack(spacing: innerSpacing) {
                    
                    if store.selection?.sftpRpc == true{
                        // connection status
                        
                        
                        if TunnelManagerHolder.shared.activeTunnels.count == 0 {
                            //connecting
                            Image(systemName: "arrow.up.arrow.down")
                                    .scaleEffect(x: -1, y: 1)
                                    .foregroundColor(.orange)
                            #if os(iOS)
                                    .symbolEffect(.bounce.up.byLayer, options: .repeat(.continuous))
                            #endif
                        } else {
                            Image(systemName: "arrow.up.arrow.down")
                                        .scaleEffect(x: -1, y: 1)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.green,.blue)
                                        .foregroundColor(.green)
                            
                        }
                    }  else {
                        // no rpc
                        Image(systemName: "arrow.up.arrow.down")
                                    .scaleEffect(x: -1, y: 1)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.green,.blue)
                                    .foregroundColor(.green)
                    }
                    
                    VStack(alignment:.leading) {
                        Text("\(activeTorrents)/\(totalTorrents)")
                            .font(.caption)
                        Text("Active").font(.caption2)
                    }
                }
                
                
                // Visible torrents
                HStack(spacing: innerSpacing) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(filterdCount >= totalTorrents  ? .blue : .orange, .blue)
                    VStack( alignment: .leading) {
                    Text("\(filterdCount)/\(totalTorrents)")
                        .font(.caption)
                    Text("Visible") .font(.caption2)
                }
                }
                
                // Free space
                HStack(spacing: innerSpacing) {
                    //Disk Icon
                    //conencting / disconnected
                    if store.selection?.sftpBrowse == true && ftpServerCount == 0    {

                        Image(systemName: "internaldrive")
                            .foregroundColor(.orange)

                    } else {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.blue)
                    }
                    VStack( alignment: .leading) {
                        Text(freeSpaceFormatted)
                            .font(.caption)
                        Text("Available") .font(.caption2)
                    }
                }
                Spacer()
                
                HStack {
                    Button {
                        showServerSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                
                
                Spacer()
                
            }
        }
        .scaleEffect(scale)
        .padding(.horizontal, horizontalPadding)
        #if os(iOS)
        .padding(.top, 15)
        .padding(.bottom, verticalPadding)
        #else
        .padding(.vertical, verticalPadding)
        #endif
        #if os(iOS)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .onAppear {
            startRefreshCycle()
            updateStats()
            startFTPStatusTimer()
        }
        .onDisappear {
            stopRefreshCycle()
            stopFTPStatusTimer()
        }
        .onChange(of: manager.sessionId) {
            resetStats()
            
            // Only try to update stats if we have a selected server
            if store.selection != nil {
                // Give the manager time to update its baseURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    updateStats()
                }
            }
        }
        // Restart refresh cycle when manager's refresh rate changes
        .onChange(of: manager.refreshRate) {
            startRefreshCycle()
        } .padding(.top, 0)
            .onChange(of: manager.fetchTimer?.isValid){
                if manager.fetchTimer?.isValid == true{
                    startRefreshCycle()
                }else{
                    stopRefreshCycle()
                }
            }
    }
    
    private func startRefreshCycle() {
        stopRefreshCycle() // Ensure no duplicate timers
        
        // Get refresh rate from manager and calculate our interval
        let baseRefreshRate = Double(manager.refreshRate)
        let refreshInterval: TimeInterval
        
        if baseRefreshRate > 15 {
            // If torrent refresh is more than 15 seconds, use the same interval
            refreshInterval = baseRefreshRate
        } else {
            // Otherwise refresh at half the frequency (double the interval)
            refreshInterval = max(baseRefreshRate * 2, 2.0) // Minimum 2 seconds
        }
        
        // Create a new timer
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            updateStats()
        }
    }
    
    private func stopRefreshCycle() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
    }
    
    private func resetStats() {
        downloadSpeed = 0
        uploadSpeed = 0
        activeTorrents = 0
        totalTorrents = 0
        freeSpace = 0
    }
    
    private func updateStats() {
        // Cancel any ongoing task
        refreshTask?.cancel()
        
        // Check if we have a server selected
        guard store.selection != nil, manager.baseURL != nil else {
            resetStats()
            return
        }
        
        // Create a new task for fetching stats
        refreshTask = Task {
            do {
                // Get session statistics
                let sessionStats = try await manager.getSessionStats()
                
                // Update UI on main thread
                await MainActor.run {
                    downloadSpeed = sessionStats.downloadSpeed
                    uploadSpeed = sessionStats.uploadSpeed
                    activeTorrents = sessionStats.activeTorrentCount
                    totalTorrents = sessionStats.torrentCount
                }
                
                // Get session information to retrieve download directory
                let sessionInfo = try await manager.getSessionInfo()
                await MainActor.run {
                    downloadDir = sessionInfo
                }
                
                // Get free space for download directory
                let downloadDirForFreeSpace = try await manager.getDownloadDirectory() ?? ""
                if !downloadDirForFreeSpace.isEmpty {
                    let spaceInfo = try await manager.getFreeSpace(path: downloadDirForFreeSpace)
                    await MainActor.run {
                        freeSpace = spaceInfo.freeSpace
                    }
                }
            } catch {
                print("Error updating server stats: \(error)")
            }
        }
    }
    
    private func startFTPStatusTimer() {
        stopFTPStatusTimer()
#if os(iOS)
        ftpStatusTimer = Timer.scheduledTimer(withTimeInterval: ftpServerCount > 0 ? 5.0 : 1.0, repeats: true) { _ in
            Task {
                let count = await SimpleFTPServerManager.shared.activeServersCount()
                await MainActor.run {
                    if ftpServerCount != count {
                        ftpServerCount = count
                        // Restart timer with new interval if status changed
                        stopFTPStatusTimer()
                        startFTPStatusTimer()
                    } else {
                        ftpServerCount = count
                    }
                }
            }
        }
#else
        ftpStatusTimer = Timer.scheduledTimer(withTimeInterval: ftpServerCount > 0 ? 5.0 : 1.0, repeats: true) { _ in
            // On macOS, check the file system for each mount
            let servers = ServerMountManager.shared.servers.filter { $0.sftpBrowse }
            var count = 0
            for server in servers {
                if let mountKey = ServerMountManager.shared.getMountKey(for: server) {
                    let mountPath = ServerMountUtilities.getMountPath(for: mountKey)
                    if ServerMountManager.shared.isPathMounted(mountKey) {
                        count += 1
                    }
                }
            }
            DispatchQueue.main.async {
                if ftpServerCount != count {
                    ftpServerCount = count
                    // Restart timer with new interval if status changed
                    stopFTPStatusTimer()
                    startFTPStatusTimer()
                } else {
                    ftpServerCount = count
                }
            }
        }
#endif
    }
    
    private func stopFTPStatusTimer() {
        ftpStatusTimer?.invalidate()
        ftpStatusTimer = nil
    }
    
    // Format bytes to human-readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: "Zero", with: "0")
    }
}

// Helper extension for TorrentManager to fetch session stats
extension TorrentManager {
    struct SessionStats: Codable {
        let activeTorrentCount: Int
        let downloadSpeed: Int64
        let pausedTorrentCount: Int
        let torrentCount: Int
        let uploadSpeed: Int64
    }
    
    struct FreeSpaceInfo: Codable {
        let path: String
        let freeSpace: Int64
        
        enum CodingKeys: String, CodingKey {
            case path
            case freeSpace = "size-bytes"
        }
    }
    
    func getSessionStats() async throws -> SessionStats {
        struct SessionStatsResponse: Codable {
            let arguments: SessionStats
            let result: String
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let requestDict: [String: Any] = ["method": "session-stats"]
        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        urlRequest.httpBody = requestData
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409,
           let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
            sessionId = newSessionId
            return try await getSessionStats()
        }
        
        let decoder = JSONDecoder()
        let responseObject = try decoder.decode(SessionStatsResponse.self, from: data)
        return responseObject.arguments
    }
    
    func getSessionInfo() async throws -> String {
        struct SessionInfoResponse: Codable {
            let arguments: Arguments
            let result: String
            
            struct Arguments: Codable {
                let downloadDir: String
                
                enum CodingKeys: String, CodingKey {
                    case downloadDir = "download-dir"
                }
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let requestDict: [String: Any] = ["method": "session-get"]
        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        urlRequest.httpBody = requestData
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409,
           let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
            sessionId = newSessionId
            return try await getSessionInfo()
        }
        
        let decoder = JSONDecoder()
        let responseObject = try decoder.decode(SessionInfoResponse.self, from: data)
        return responseObject.arguments.downloadDir
    }
    
    func getFreeSpace(path: String) async throws -> FreeSpaceInfo {
        struct FreeSpaceRequest: Codable {
            var method = "free-space"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let path: String
            }
        }
        
        struct FreeSpaceResponse: Codable {
            let arguments: FreeSpaceInfo
            let result: String
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = FreeSpaceRequest(arguments: .init(path: path))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409,
           let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
            sessionId = newSessionId
            return try await getFreeSpace(path: path)
        }
        
        let decoder = JSONDecoder()
        let responseObject = try decoder.decode(FreeSpaceResponse.self, from: data)
        return responseObject.arguments
    }
}
