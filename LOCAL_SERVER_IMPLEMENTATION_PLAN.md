# Local Server Implementation Plan
## Throttle 2 - Local Transmission Server Feature

**Target Platform:** Apple Silicon Macs only  
**Date Created:** August 18, 2025  
**Status:** Planning Phase

---

## 🎯 Overview

Add a local Transmission server option that allows Apple Silicon Mac users to run their own Transmission daemon locally, with automatic SSH key generation, iCloud synchronization, and zero-config remote access for devices on the same iCloud account.

---

## 🏗️ Architecture Decisions

### **Security & Authentication**
- Use iCloud Keychain for SSH key synchronization
- Use logged-in user account (non-invasive approach)
- Generate unique SSH keys per local server instance
- Careful SSH configuration to avoid locking users out

### **Network Strategy**
- Simultaneous bidirectional requests for CGNAT traversal
- Build on existing SSH client implementation
- Zero-config discovery for same iCloud account clients
- Port knocking over iCloud for remote access

### **Process Management**
- Optional daemon startup: login vs app launch
- Integrate with existing mount helper infrastructure
- Graceful handling of existing Transmission instances
- Resource bundling: use included transmission-daemon/remote

### **User Experience**
- One-click setup with intelligent defaults
- Detect and offer control of existing vs embedded Transmission
- Settings synchronization across devices via iCloud
- Local server appears next to "Add Server" as `[Local]` button

---

## 📋 Implementation Phases

### **Phase 1: Core Data Model Updates**
**Files to modify:**
- `Throttle 2/CoreData.xcdatamodeld/CoreData.xcdatamodel/contents`

**Changes needed:**
- Add `isLocal` (Boolean) property to ServerEntity
- Add `localPort` (Integer 32) property 
- Add `localDaemonEnabled` (Boolean) property
- Add `localStartOnLogin` (Boolean) property
- Add `localRemoteAccess` (Boolean) property
- Add `localSSHKeyGenerated` (Boolean) property

### **Phase 2: UI Infrastructure**
**Files to modify:**
- `Throttle 2/Settings/ServersView.swift`
- `Throttle 2/Server/ServerSettings.swift`

**2.1 Add Local Server Button**
- Modify `ServersListView` toolbar to show `[Local]` button next to existing "Add Server"
- Only show on Apple Silicon Macs (`sysctl machdep.cpu.brand_string` contains "Apple")
- Button creates new ServerEntity with `isLocal = true`

**2.2 Server Settings Tab for Local**
- Expand `localSettingsForm` in `ServerSettings.swift` (currently stub at line 678)
- Add tab for local-specific settings:
  - Port configuration (default: 9091)
  - Default download folder picker
  - Start daemon on login toggle
  - Enable remote access toggle
  - SSH key management section

**2.3 Local Server Configuration Form**
- Modify `ServerEditView` to handle local server type
- Hide irrelevant fields (SSH host, tunneling, etc.) for local servers
- Pre-populate dummy values:
  - `url = "127.0.0.1"`
  - `pathServer = "/"`
  - `pathFilesystem = "/"`
  - `sftpBrowse = false`
  - `sftpRpc = false`

### **Phase 3: Local Transmission Manager**
**New file:** `Throttle 2/Server/LocalTransmissionManager.swift`

**3.1 Process Lifecycle Management**
```swift
class LocalTransmissionManager: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var port: Int = 9091
    
    func startDaemon() async throws
    func stopDaemon() async throws
    func getDaemonStatus() -> Bool
    func checkPortAvailability(_ port: Int) -> Bool
    func getTransmissionConfigPath() -> URL
    func writeTransmissionConfig() throws
}
```

**3.2 Configuration Management**
- Create transmission daemon config file
- Handle port conflicts (scan for available ports)
- Manage download directories
- Set up RPC authentication

**3.3 Process Integration**
- Use bundled `Resources/transmission/transmission-daemon`
- Integrate with existing mount helper for startup options
- Handle daemon crashes and restarts

### **Phase 4: SSH Key Management**
**New file:** `Throttle 2/SSH/LocalSSHKeyManager.swift`

**4.1 Key Generation & Storage**
```swift
class LocalSSHKeyManager {
    static func generateSSHKeyPair() throws -> (publicKey: String, privateKey: String)
    static func storeKeysInKeychain(publicKey: String, privateKey: String) throws
    static func getKeysFromKeychain() throws -> (publicKey: String, privateKey: String)?
    static func enableSSHForCurrentUser() throws
    static func addPublicKeyToAuthorizedKeys(_ publicKey: String) throws
    static func removePublicKeyFromAuthorizedKeys(_ publicKey: String) throws
}
```

**4.2 SSH Configuration**
- Check if SSH is enabled for current user
- Safely add/remove authorized_keys entries
- Detect existing SSH configurations
- Prevent lockouts when disabling server

**4.3 iCloud Keychain Integration**
- Store SSH keys using existing Keychain infrastructure
- Sync across devices on same iCloud account
- Handle key conflicts and updates

### **Phase 5: Existing Transmission Detection**
**New file:** `Throttle 2/Helpers/TransmissionDetector.swift`

**5.1 System Detection**
```swift
class TransmissionDetector {
    static func detectRunningTransmission() -> TransmissionInstance?
    static func getTransmissionProcesses() -> [ProcessInfo]
    static func canControlExistingInstance() -> Bool
    static func getExistingInstancePort() -> Int?
}
```

**5.2 User Choice Integration**
- Present options when existing Transmission detected
- Store user preference in AppStorage
- Allow toggle in settings for future decisions

### **Phase 6: Integration Points**

**6.1 Mount Helper Integration**
**File to modify:** `Resources/com.srgim.throttle2.mounter.plist`
- Add local daemon startup option
- Check `localStartOnLogin` setting
- Coordinate with existing mount operations

**6.2 Main App Integration**
**Files to modify:**
- `Throttle 2/Throttle_2App.swift` - Add menu items for local server control
- `Throttle 2/Helpers/ServerManager.swift` - Handle local server connections
- `Throttle 2/SSH/ServerInit.swift` - Skip tunneling for local servers

**6.3 Settings Storage**
- Use AppStorage for local server preferences
- Integrate with existing CloudKit sync for cross-device settings

### **Phase 7: Remote Access & Discovery**
**Future implementation - after Phase 6 complete**

**7.1 NAT Hole Punching via iCloud Coordination**
Based on analysis of `bore` (https://github.com/ekzhang/bore), implement NAT traversal using iCloud as coordination mechanism:

**Core Strategy:**
- Use iCloud CloudKit as the coordination server (instead of `bore.pub`)
- Implement simultaneous bidirectional TCP connection attempts
- Server and client both initiate connections at the same time to "punch" through NAT/CGNAT

**Implementation Plan:**
```swift
// New file: `Throttle 2/Network/NATTraversal.swift`
class NATTraversalManager {
    // iCloud coordination
    func announceServerAvailability(serverInfo: LocalServerInfo) // Server announces via CloudKit
    func discoverAvailableServers() -> [RemoteServerInfo]       // Client discovers via CloudKit
    
    // Hole punching protocol
    func initiateHolePunch(to: RemoteServerInfo) async throws   // Client initiates
    func respondToHolePunch(from: ClientInfo) async throws      // Server responds
    
    // Based on bore's approach but using iCloud for coordination
    func simultaneousTCPConnect(localPort: Int, remoteIP: String, remotePort: Int) async throws -> TCPConnection
}
```

**Key Components:**
1. **iCloud Coordination Record:** Store server IP, port, availability status, and timing info
2. **Synchronized Connection Attempts:** Both ends attempt connection simultaneously 
3. **STUN-like Behavior:** Discover external IP/port through connection attempts
4. **Fallback Chain:** UPnP → NAT-PMP → Hole Punching → VPN/Relay

**7.2 Zero-Config Discovery via iCloud**
- Server publishes availability to CloudKit with external IP/port discovery
- Clients poll CloudKit for available servers on same iCloud account
- Automatic connection establishment using discovered hole-punched ports
- Handle network changes by re-announcing/re-discovering

**7.3 Protocol Design (Inspired by `bore`):**
```
1. Server starts local transmission daemon
2. Server discovers external IP via test connections
3. Server announces to iCloud: {externalIP, port, timestamp, deviceID}
4. Client discovers server via iCloud CloudKit query
5. Both initiate TCP connections simultaneously (hole punching)
6. Successful connection becomes SSH tunnel for existing Throttle workflow
```

**Technical Notes:**
- `bore` uses control port 7835 + dynamic data ports
- We'll use SSH (port 22) as the target after hole punching succeeds
- iCloud CloudKit replaces `bore`'s central coordination server
- Existing SSH client infrastructure handles authentication/security post-connection

---

## 🗂️ File Organization

### **New Files to Create:**
- `Throttle 2/Server/LocalTransmissionManager.swift`
- `Throttle 2/SSH/LocalSSHKeyManager.swift`
- `Throttle 2/Helpers/TransmissionDetector.swift`

### **Files to Modify:**
- `Throttle 2/CoreData.xcdatamodeld/CoreData.xcdatamodel/contents`
- `Throttle 2/Settings/ServersView.swift`
- `Throttle 2/Server/ServerSettings.swift`
- `Throttle 2/Throttle_2App.swift`
- `Throttle 2/Helpers/ServerManager.swift`
- `Throttle 2/SSH/ServerInit.swift`
- `Resources/com.srgim.throttle2.mounter.plist`

---

## 🧪 Testing Strategy

### **Unit Tests:**
- SSH key generation and validation
- Port availability checking
- Configuration file generation
- Daemon process management

### **Integration Tests:**
- Local server creation and connection
- Existing Transmission detection
- Mount helper integration
- iCloud Keychain synchronization

### **User Testing:**
- Clean install flow (no existing Transmission)
- Existing Transmission conflict resolution
- Cross-device discovery and connection
- SSH key synchronization across devices

---

## 🚨 Risk Mitigation

### **Security Risks:**
- **SSH lockout:** Always test SSH configuration before applying
- **Key conflicts:** Handle multiple devices generating keys simultaneously
- **Unauthorized access:** Proper key rotation and revocation

### **Technical Risks:**
- **Port conflicts:** Dynamic port allocation with fallbacks
- **Process crashes:** Robust daemon monitoring and restart
- **Network issues:** Graceful handling of connectivity problems

### **User Experience Risks:**
- **Complex setup:** Provide clear error messages and recovery options
- **Performance impact:** Resource monitoring and limits
- **Conflicting software:** Clear detection and user choice

---

## 📊 Success Metrics

### **Phase 1-3 Success:**
- Local server can be created and started
- Transmission daemon runs stably
- Local connections work reliably

### **Phase 4-6 Success:**
- SSH keys generate and sync via iCloud
- Remote access works from same iCloud account
- Existing Transmission detection works correctly

### **Phase 7 Success:**
- Zero-config remote connection establishment
- CGNAT traversal success rate >80%
- Cross-device discovery within 30 seconds

---

## 🔄 Future Enhancements

### **Advanced Features:**
- Load balancing across multiple local servers
- Bandwidth prioritization and QoS
- Advanced port knocking sequences
- VPN integration for enhanced security

### **Management Features:**
- Local server health monitoring
- Automatic backup and restore
- Usage analytics and reporting
- Advanced firewall integration

---

## 📝 Implementation Notes

### **Apple Silicon Detection:**
```bash
sysctl machdep.cpu.brand_string
# Should contain "Apple M1", "Apple M2", etc.
```

### **Bundled Resources:**
- `Resources/transmission/transmission-daemon`
- `Resources/transmission/transmission-remote`
- `Resources/transmission/transmission-create`

### **Default Configuration:**
- Port: 9091 (scan up if occupied)
- Download directory: `~/Downloads/Throttle2`
- RPC path: `/transmission/rpc`
- Authentication: auto-generated credentials

### **Integration with Existing Features:**
- Use existing SSH client implementation in `Throttle 2/SSH/`
- Leverage existing server management in `Throttle 2/Helpers/ServerManager.swift`
- Build on existing mount helper infrastructure
- Utilize existing iCloud Keychain patterns

---

*This plan should be updated as implementation progresses and requirements evolve.*
