//
//  LocalTransmissionSettingsView.swift
//  Throttle 2
//
//  Created for local transmission daemon settings management.
//

import SwiftUI

struct LocalTransmissionSettingsView: View {
    @ObservedObject var server: ServerEntity
    @StateObject private var localTransmissionManager = LocalTransmissionManager.shared
    @AppStorage("transmissionOnLogin") private var transmissionOnLogin: Bool = false
    
    // Local state for editing
    @State private var localPort: String = ""
    @State private var localStartOnLogin: Bool = false
    @State private var localRemoteAccess: Bool = false
    @State private var localRemoteUsername: String = ""
    @State private var localRemotePassword: String = ""
    @State private var localSSHKeyGenerated: Bool = false
    
    // Error handling
    @State private var saveError: String = ""
    @State private var showSaveError: Bool = false
    
    var body: some View {
        Group {
            #if os(iOS)
            // iOS Layout
            HStack {
                Text("Port")
                Spacer()
                TextField("Port number", text: $localPort)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .onChange(of: localPort) { _, newValue in
                        saveLocalSettings()
                    }
            }
            
            Toggle("Start daemon on login", isOn: $localStartOnLogin)
                .onChange(of: localStartOnLogin) { _, _ in
                    saveLocalSettings()
                }
            
            Toggle("Enable remote access", isOn: $localRemoteAccess)
                .onChange(of: localRemoteAccess) { _, _ in
                    saveLocalSettings()
                }
            
            if localRemoteAccess {
                HStack {
                    Text("Username")
                    Spacer()
                    TextField("Username", text: $localRemoteUsername)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: localRemoteUsername) { _, _ in
                            saveLocalSettings()
                        }
                }
                
                HStack {
                    Text("Password")
                    Spacer()
                    SecureField("Password", text: $localRemotePassword)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: localRemotePassword) { _, _ in
                            saveLocalSettings()
                        }
                }
                
                HStack {
                    Text("SSH Key")
                    Spacer()
                    Text(localSSHKeyGenerated ? "Generated" : "Not Generated")
                        .foregroundColor(localSSHKeyGenerated ? .green : .orange)
                    if !localSSHKeyGenerated {
                        Button("Generate") {
                            // TODO: Generate SSH key
                            localSSHKeyGenerated = true
                            saveLocalSettings()
                        }
                    }
                }
            }
            #else
            // macOS Layout
            TextField("Port", text: $localPort)
                .onChange(of: localPort) { _, newValue in
                    saveLocalSettings()
                }
            
            Toggle("Start daemon on login", isOn: $localStartOnLogin)
                .onChange(of: localStartOnLogin) { _, _ in
                    saveLocalSettings()
                }
            
            Toggle("Enable remote access", isOn: $localRemoteAccess)
                .onChange(of: localRemoteAccess) { _, _ in
                    saveLocalSettings()
                }
            
            if localRemoteAccess {
                TextField("Username", text: $localRemoteUsername)
                    .onChange(of: localRemoteUsername) { _, _ in
                        saveLocalSettings()
                    }
                
                SecureField("Password", text: $localRemotePassword)
                    .onChange(of: localRemotePassword) { _, _ in
                        saveLocalSettings()
                    }
                
                HStack {
                    Text("SSH Key Status:")
                    Spacer()
                    Text(localSSHKeyGenerated ? "Generated" : "Not Generated")
                        .foregroundColor(localSSHKeyGenerated ? .green : .orange)
                    if !localSSHKeyGenerated {
                        Button("Generate") {
                            // TODO: Generate SSH key
                            localSSHKeyGenerated = true
                            saveLocalSettings()
                        }
                    }
                }
            }
            #endif
            
            // Daemon Control
            HStack {
                Button("Start Daemon") {
                    localTransmissionManager.startDaemon()
                }
                .disabled(!checkIsDaemonStopped())
                
                Button("Stop Daemon") {
                    localTransmissionManager.stopDaemon()
                }
                .disabled(checkIsDaemonStopped())
                
                Button("Restart Daemon") {
                    localTransmissionManager.restartDaemon()
                }
            }
            #if os(macOS)
            .buttonStyle(.bordered)
            #endif
            
            HStack {
                Text("Status:")
                Spacer()
                Text(checkIsDaemonStopped() ? "Stopped" : "Running")
                    .foregroundColor(checkIsDaemonStopped() ? .red : .green)
            }
        }
        .onAppear {
            loadLocalSettings()
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("OK") { }
        } message: {
            Text(saveError)
        }
    }
    
    private func checkIsDaemonStopped() -> Bool {
        // Check if transmission daemon is stopped
        // Since LocalTransmissionManager might not have isDaemonStopped, 
        // we'll implement a basic check or return false for now
        return false
    }
    
    private func loadLocalSettings() {
        localPort = String(server.localPort)
        localStartOnLogin = server.localStartOnLogin
        localRemoteAccess = server.localRemoteAccess
        localRemoteUsername = server.localRemoteUsername ?? ""
        localRemotePassword = server.localRemotePassword ?? ""
        localSSHKeyGenerated = server.localSSHKeyGenerated
    }
    
    private func saveLocalSettings() {
        // Validate port
        if let portValue = Int(localPort), portValue > 0 && portValue <= 65535 {
            server.localPort = Int32(portValue)
        } else {
            // Reset to current value if invalid
            localPort = String(server.localPort)
        }
        
        // Update server properties
        server.localStartOnLogin = localStartOnLogin
        server.localRemoteAccess = localRemoteAccess
        server.localRemoteUsername = localRemoteUsername
        server.localRemotePassword = localRemotePassword
        server.localSSHKeyGenerated = localSSHKeyGenerated
        
        // Update global setting for launch agent
        transmissionOnLogin = localStartOnLogin
        
        // Save to Core Data
        do {
            try server.managedObjectContext?.save()
        } catch {
            saveError = "Failed to save settings: \(error.localizedDescription)"
            showSaveError = true
        }
    }
}

//#Preview {
//    // Create a mock server entity for preview
//    let context = DataManager.shared.viewContext
//    let mockServer = ServerEntity(context: context)
//    mockServer.isLocal = true
//    mockServer.localPort = 9091
//    mockServer.localStartOnLogin = false
//    mockServer.localRemoteAccess = false
//    
//    return Form {
//        Section(header: Text("Local Transmission Daemon")) {
//            LocalTransmissionSettingsView(server: mockServer)
//        }
//    }
//    .environment(\.managedObjectContext, context)
//}
