//
//  TransmissionSettingsView.swift
//  Throttle 2
//
//  Created for the Transmission server settings page.
//

import SwiftUI

struct TransmissionSettingsView: View {
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    // Tab selection state
    @State private var selectedTab = 0
    
    // General settings
    @State private var downloadDir: String = ""
    @State private var incompleteDir: String = ""
    @State private var incompleteDirEnabled: Bool = false
    @State private var startAddedTorrents: Bool = true
    @State private var renamePartialFiles: Bool = true
    
    // Download settings
    @State private var downloadQueueEnabled: Bool = true
    @State private var downloadQueueSize: Int = 5
    @State private var seedQueueEnabled: Bool = true
    @State private var seedQueueSize: Int = 5
    @State private var queueStalledEnabled: Bool = true
    @State private var queueStalledMinutes: Int = 30
    @State private var downloadLimitEnabled: Bool = false
    @State private var downloadLimit: Int = 100
    @State private var uploadLimitEnabled: Bool = false
    @State private var uploadLimit: Int = 100
    
    // Network settings
    @State private var peerPort: Int = 51413
    @State private var randomPort: Bool = false
    @State private var portForwardingEnabled: Bool = true
    @State private var pexEnabled: Bool = true
    @State private var dhtEnabled: Bool = true
    @State private var lpdEnabled: Bool = true
    @State private var utpEnabled: Bool = true
    @State private var encryptionMode: String = "preferred"
    
    // Speed settings
    @State private var altSpeedEnabled: Bool = false
    @State private var altSpeedDown: Int = 50
    @State private var altSpeedUp: Int = 50
    @State private var altSpeedTimeEnabled: Bool = false
    @State private var altSpeedTimeBegin: Int = 540  // 9:00 AM in minutes
    @State private var altSpeedTimeEnd: Int = 1080   // 6:00 PM in minutes
    @State private var altSpeedTimeDay: Int = 127    // All days
    
    // Date objects for time pickers
    @State private var startTime: Date = Date()
    @State private var endTime: Date = Date()
    
    // Weekday selections
    @State private var selectedDays: [Bool] = [false, false, false, false, false, false, false]
    
    // State
    @State private var isLoading: Bool = true
    @State private var showingFileBrowser: Bool = false
    @State private var browsingForField: String = ""
    @State private var saveError: String? = nil
    @State private var showSaveError: Bool = false
    @State private var showSuccess: Bool = false
    
    // Tab items
    private let tabs = ["General", "Download", "Network"]
    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    
    var body: some View {
        #if os(iOS)
        iOSView
        #else
        macOSView
        #endif
    }
    
    // MARK: - Platform Specific Views
    
    #if os(iOS)
    var iOSView: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tabs
                HStack {
                    ForEach(0..<tabs.count, id: \.self) { index in
                        Button(action: {
                            withAnimation {
                                self.selectedTab = index
                            }
                        }) {
                            Text(tabs[index])
                                .font(.subheadline)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(selectedTab == index ?
                                            Color.accentColor.opacity(0.2) : Color.clear)
                                .cornerRadius(6)
                                .foregroundColor(selectedTab == index ? .primary : .secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if index < tabs.count - 1 {
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
                
                Divider().padding(.top, 8)
                
                if isLoading {
                    Spacer()
                    ProgressView("Loading settings...")
                    Spacer()
                } else {
                    ScrollView {
                        VStack {
                            switch selectedTab {
                            case 0: generalSettingsForm
                            case 1: downloadSettingsForm
                            case 2: networkSettingsForm
                            default: EmptyView()
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSettings()
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                loadSettings()
            }
            .sheet(isPresented: $showingFileBrowser) {
                NavigationView{
                    if browsingForField == "download" {
                        FileBrowserView(
                            currentPath: downloadDir,
                            basePath: (store.selection?.pathServer!) ?? "/",
                            server: store.selection,
                            onFolderSelected: { folderPath in
                                downloadDir = folderPath
                                showingFileBrowser = false
                            }
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cancel") {
                                    showingFileBrowser = false
                                }
                            }
                        }
                    } else {
                        FileBrowserView(
                            currentPath: incompleteDir,
                            basePath: (store.selection?.pathServer) ?? "/",
                            server: store.selection,
                            onFolderSelected: { folderPath in
                                incompleteDir = folderPath
                                showingFileBrowser = false
                            }
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cancel") {
                                    showingFileBrowser = false
                                }
                            }
                        }
                    }
                }
            }
            .alert(isPresented: $showSaveError) {
                Alert(
                    title: Text("Error"),
                    message: Text(saveError ?? "Failed to save settings"),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: $showSuccess) {
                Alert(
                    title: Text("Success"),
                    message: Text("Settings saved successfully"),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
    #else
    var macOSView: some View {
        VStack(spacing: 0) {
            // Tabs
            HStack {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button(action: {
                        withAnimation {
                            self.selectedTab = index
                        }
                    }) {
                        Text(tabs[index])
                            .font(.headline)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(selectedTab == index ?
                                        Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(8)
                            .foregroundColor(selectedTab == index ? .primary : .secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if index < tabs.count - 1 {
                        Spacer()
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            Divider().padding(.top, 8)
            
            if isLoading {
                Spacer()
                ProgressView("Loading settings...")
                Spacer()
            } else {
                ScrollView {
                    VStack {
                        switch selectedTab {
                        case 0: generalSettingsForm
                        case 1: downloadSettingsForm
                        case 2: networkSettingsForm
                        default: EmptyView()
                        }
                    }
                    .padding()
                }
            }
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                
                Spacer()
                
                Button("Save") {
                    saveSettings()
                }
                .disabled(isLoading)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .onAppear {
            loadSettings()
        }
        .sheet(isPresented: $showingFileBrowser) {
            if browsingForField == "download" {
                FileBrowserView(
                    currentPath: downloadDir,
                    basePath: "/",
                    server: store.selection,
                    onFolderSelected: { folderPath in
                        downloadDir = folderPath
                        showingFileBrowser = false
                    }
                )
                .frame(width: 600, height: 600)
            } else {
                FileBrowserView(
                    currentPath: incompleteDir,
                    basePath: "/",
                    server: store.selection,
                    onFolderSelected: { folderPath in
                        incompleteDir = folderPath
                        showingFileBrowser = false
                    }
                )
                .frame(width: 600, height: 600)
            }
        }
        .alert(isPresented: $showSaveError) {
            Alert(
                title: Text("Error"),
                message: Text(saveError ?? "Failed to save settings"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $showSuccess) {
            Alert(
                title: Text("Success"),
                message: Text("Settings saved successfully"),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    #endif
    
    // MARK: - Setting Forms
    
    var generalSettingsForm: some View {
        Group {
            settingsSection(title: "Download Locations") {
                VStack(alignment: .leading) {
                    Text("Download Directory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        TextField("Download directory", text: $downloadDir)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if store.selection?.sftpBrowse == true {
                            Button(action: {
                                browsingForField = "download"
                                showingFileBrowser = true
                            }) {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else if store.selection?.fsBrowse == true {
                            #if os(macOS)
                            Button("", systemImage: "folder") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.allowsOtherFileTypes = false
                                panel.canChooseDirectories = true
                                
                                // Set the initial directory to the current downloadDir
                                if let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                   let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                    
                                    let localPath = downloadDir.replacingOccurrences(of: serverPath, with: filesystemPath)
                                    
                                    let directoryURLString = localPath.hasPrefix("file://") ?
                                    localPath :
                                    "file://" + localPath
                                    
                                    if let directoryURL = URL(string: directoryURLString) {
                                        panel.directoryURL = directoryURL
                                    }
                                }
                                
                                if panel.runModal() == .OK,
                                   let fpath = panel.url,
                                   let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                   let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                    
                                    // Convert from filesystem path back to server path
                                    let movepath = fpath.absoluteString.replacingOccurrences(of: "file://" + filesystemPath, with: serverPath)
                                    downloadDir = movepath
                                }
                            }.labelsHidden()
                            #endif
                        }
                    }
                }
                
                Toggle("Store incomplete torrents in a different location", isOn: $incompleteDirEnabled)
                
                if incompleteDirEnabled {
                    HStack {
                        TextField("Incomplete directory", text: $incompleteDir)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        if store.selection?.sftpBrowse == true {
                            Button(action: {
                                browsingForField = "incomplete"
                                showingFileBrowser = true
                            }) {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else if store.selection?.fsBrowse == true {
                            #if os(macOS)
                            Button("", systemImage: "folder") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.allowsOtherFileTypes = false
                                panel.canChooseDirectories = true
                                
                                // Set the initial directory to the current downloadDir
                                if let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                   let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                    
                                    let localPath = downloadDir.replacingOccurrences(of: serverPath, with: filesystemPath)
                                    
                                    let directoryURLString = localPath.hasPrefix("file://") ?
                                    localPath :
                                    "file://" + localPath
                                    
                                    if let directoryURL = URL(string: directoryURLString) {
                                        panel.directoryURL = directoryURL
                                    }
                                }
                                
                                if panel.runModal() == .OK,
                                   let fpath = panel.url,
                                   let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                   let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                    
                                    // Convert from filesystem path back to server path
                                    let movepath = fpath.absoluteString.replacingOccurrences(of: "file://" + filesystemPath, with: serverPath)
                                    incompleteDir = movepath
                                }
                            }.labelsHidden()
                            #endif
                        }
                    }
                }
            }
            
            settingsSection(title: "Behavior") {
                Toggle("Start torrents when added", isOn: $startAddedTorrents)
                Toggle("Append .part to incomplete files", isOn: $renamePartialFiles)
            }
        }
    }
    
    var downloadSettingsForm: some View {
        Group {
            settingsSection(title: "Queue") {
                Toggle("Limit active downloads", isOn: $downloadQueueEnabled)
                
                if downloadQueueEnabled {
                    Stepper(value: $downloadQueueSize, in: 1...100) {
                        Text("Maximum active downloads: \(downloadQueueSize)")
                    }
                }
                
                Toggle("Limit active seeds", isOn: $seedQueueEnabled)
                
                if seedQueueEnabled {
                    Stepper(value: $seedQueueSize, in: 1...100) {
                        Text("Maximum active seeds: \(seedQueueSize)")
                    }
                }
                
                Toggle("Consider torrents 'stalled' when inactive", isOn: $queueStalledEnabled)
                
                if queueStalledEnabled {
                    Stepper(value: $queueStalledMinutes, in: 1...1000) {
                        Text("Stalled minutes: \(queueStalledMinutes)")
                    }
                }
            }
            
            settingsSection(title: "Bandwidth Limits") {
                Toggle("Limit download rate", isOn: $downloadLimitEnabled)
                
                if downloadLimitEnabled {
                    HStack {
                        Text("Download limit (KB/s):")
                        Spacer()
                        TextField("", value: $downloadLimit, formatter: NumberFormatter())
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Toggle("Limit upload rate", isOn: $uploadLimitEnabled)
                
                if uploadLimitEnabled {
                    HStack {
                        Text("Upload limit (KB/s):")
                        Spacer()
                        TextField("", value: $uploadLimit, formatter: NumberFormatter())
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            
            settingsSection(title: "Alternative Speed Limits") {
                Toggle("Enable alternative speed limits", isOn: $altSpeedEnabled)
                
                HStack {
                    Text("Download limit (KB/s):")
                    Spacer()
                    TextField("", value: $altSpeedDown, formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Text("Upload limit (KB/s):")
                    Spacer()
                    TextField("", value: $altSpeedUp, formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
            }
            
            settingsSection(title: "Scheduled Speed Limits") {
                Toggle("Schedule alternative speed limits", isOn: $altSpeedTimeEnabled)
                
                if altSpeedTimeEnabled {
                    HStack {
                        Text("Start time:")
                        Spacer()
                        
                        #if os(iOS)
                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .onChange(of: startTime) { _ in
                                updateAltSpeedTimeBegin()
                            }
                        #else
                        HStack {
                            let hours = Binding<Int>(
                                get: { altSpeedTimeBegin / 60 },
                                set: { newHours in
                                    altSpeedTimeBegin = (newHours * 60) + (altSpeedTimeBegin % 60)
                                }
                            )
                            
                            let minutes = Binding<Int>(
                                get: { altSpeedTimeBegin % 60 },
                                set: { newMinutes in
                                    altSpeedTimeBegin = ((altSpeedTimeBegin / 60) * 60) + newMinutes
                                }
                            )
                            
                            Picker("", selection: hours) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text("\(hour)").tag(hour)
                                }
                            }
                            .frame(width: 60)
                            .labelsHidden()
                            .pickerStyle(MenuPickerStyle())
                            
                            Text(":")
                            
                            Picker("", selection: minutes) {
                                ForEach(0..<60, id: \.self) { minute in
                                    Text(String(format: "%02d", minute)).tag(minute)
                                }
                            }
                            .frame(width: 60)
                            .labelsHidden()
                            .pickerStyle(MenuPickerStyle())
                        }
                        #endif
                    }
                    
                    HStack {
                        Text("End time:")
                        Spacer()
                        
                        #if os(iOS)
                        DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .onChange(of: endTime) { _ in
                                updateAltSpeedTimeEnd()
                            }
                        #else
                        HStack {
                            let hours = Binding<Int>(
                                get: { altSpeedTimeEnd / 60 },
                                set: { newHours in
                                    altSpeedTimeEnd = (newHours * 60) + (altSpeedTimeEnd % 60)
                                }
                            )
                            
                            let minutes = Binding<Int>(
                                get: { altSpeedTimeEnd % 60 },
                                set: { newMinutes in
                                    altSpeedTimeEnd = ((altSpeedTimeEnd / 60) * 60) + newMinutes
                                }
                            )
                            
                            Picker("", selection: hours) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text("\(hour)").tag(hour)
                                }
                            }
                            .frame(width: 60)
                            .labelsHidden()
                            .pickerStyle(MenuPickerStyle())
                            
                            Text(":")
                            
                            Picker("", selection: minutes) {
                                ForEach(0..<60, id: \.self) { minute in
                                    Text(String(format: "%02d", minute)).tag(minute)
                                }
                            }
                            .frame(width: 60)
                            .labelsHidden()
                            .pickerStyle(MenuPickerStyle())
                        }
                        #endif
                    }
                    
                    Text("Active days:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<weekdays.count, id: \.self) { index in
                            Toggle(weekdays[index], isOn: $selectedDays[index])
                                .onChange(of: selectedDays[index]) { _ in
                                    updateAltSpeedTimeDay()
                                }
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }
    
    var networkSettingsForm: some View {
        Group {
            settingsSection(title: "Peer Listening Port") {
                HStack {
                    Text("Port:")
                    Spacer()
                    TextField("", value: $peerPort, formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
                
                Toggle("Randomize port on launch", isOn: $randomPort)
                Toggle("Enable port forwarding via UPnP/NAT-PMP", isOn: $portForwardingEnabled)
            }
            
            settingsSection(title: "Peer Communication") {
                Text("Encryption:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("", selection: $encryptionMode) {
                    Text("Prefer").tag("preferred")
                    Text("Require").tag("required")
                    Text("Allow").tag("tolerated")
                }
                .pickerStyle(SegmentedPickerStyle())
                
                Toggle("Enable Peer Exchange (PEX)", isOn: $pexEnabled)
                Toggle("Enable Distributed Hash Table (DHT)", isOn: $dhtEnabled)
                Toggle("Enable Local Peer Discovery (LPD)", isOn: $lpdEnabled)
                Toggle("Enable µTP", isOn: $utpEnabled)
            }
        }
    }
    
    var localSettingsForm: some View {
        Group {
            // This is a stub for future use
        }
    }
    
    // MARK: - Helper Views
    
    func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)
            
            content()
                .padding(.leading, 4)
            
            Divider()
                .padding(.vertical, 8)
        }
    }
    
    // MARK: - Data Loading and Saving
    
    private func loadSettings() {
        isLoading = true
        
        Task {
            do {
                let sessionSettings = try await manager.getSession()
                
                await MainActor.run {
                    // General settings
                    downloadDir = sessionSettings["download-dir"] as? String ?? ""
                    incompleteDir = sessionSettings["incomplete-dir"] as? String ?? ""
                    incompleteDirEnabled = sessionSettings["incomplete-dir-enabled"] as? Bool ?? false
                    startAddedTorrents = sessionSettings["start-added-torrents"] as? Bool ?? true
                    renamePartialFiles = sessionSettings["rename-partial-files"] as? Bool ?? true
                    
                    // Download settings
                    downloadQueueEnabled = sessionSettings["download-queue-enabled"] as? Bool ?? true
                    downloadQueueSize = sessionSettings["download-queue-size"] as? Int ?? 5
                    seedQueueEnabled = sessionSettings["seed-queue-enabled"] as? Bool ?? true
                    seedQueueSize = sessionSettings["seed-queue-size"] as? Int ?? 5
                    queueStalledEnabled = sessionSettings["queue-stalled-enabled"] as? Bool ?? true
                    queueStalledMinutes = sessionSettings["queue-stalled-minutes"] as? Int ?? 30
                    downloadLimitEnabled = sessionSettings["speed-limit-down-enabled"] as? Bool ?? false
                    downloadLimit = sessionSettings["speed-limit-down"] as? Int ?? 100
                    uploadLimitEnabled = sessionSettings["speed-limit-up-enabled"] as? Bool ?? false
                    uploadLimit = sessionSettings["speed-limit-up"] as? Int ?? 100
                    
                    // Network settings
                    peerPort = sessionSettings["peer-port"] as? Int ?? 51413
                    randomPort = sessionSettings["peer-port-random-on-start"] as? Bool ?? false
                    portForwardingEnabled = sessionSettings["port-forwarding-enabled"] as? Bool ?? true
                    pexEnabled = sessionSettings["pex-enabled"] as? Bool ?? true
                    dhtEnabled = sessionSettings["dht-enabled"] as? Bool ?? true
                    lpdEnabled = sessionSettings["lpd-enabled"] as? Bool ?? true
                    utpEnabled = sessionSettings["utp-enabled"] as? Bool ?? true
                    encryptionMode = sessionSettings["encryption"] as? String ?? "preferred"
                    
                    // Speed settings
                    altSpeedEnabled = sessionSettings["alt-speed-enabled"] as? Bool ?? false
                    altSpeedDown = sessionSettings["alt-speed-down"] as? Int ?? 50
                    altSpeedUp = sessionSettings["alt-speed-up"] as? Int ?? 50
                    altSpeedTimeEnabled = sessionSettings["alt-speed-time-enabled"] as? Bool ?? false
                    altSpeedTimeBegin = sessionSettings["alt-speed-time-begin"] as? Int ?? 540
                    altSpeedTimeEnd = sessionSettings["alt-speed-time-end"] as? Int ?? 1080
                    altSpeedTimeDay = sessionSettings["alt-speed-time-day"] as? Int ?? 127
                    
                    // Setup time objects based on minutes
                    updateTimePickersFromMinutes()
                    
                    // Setup weekday selections based on bit field
                    updateSelectedDaysFromBitfield()
                    
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    showSaveError = true
                    isLoading = false
                }
            }
        }
    }
    
    private func saveSettings() {
        isLoading = true
        
        let settings: [String: Any] = [
            // General settings
            "download-dir": downloadDir,
            "incomplete-dir": incompleteDir,
            "incomplete-dir-enabled": incompleteDirEnabled,
            "start-added-torrents": startAddedTorrents,
            "rename-partial-files": renamePartialFiles,
            
            // Download settings
            "download-queue-enabled": downloadQueueEnabled,
            "download-queue-size": downloadQueueSize,
            "seed-queue-enabled": seedQueueEnabled,
            "seed-queue-size": seedQueueSize,
            "queue-stalled-enabled": queueStalledEnabled,
            "queue-stalled-minutes": queueStalledMinutes,
            "speed-limit-down-enabled": downloadLimitEnabled,
            "speed-limit-down": downloadLimit,
            "speed-limit-up-enabled": uploadLimitEnabled,
            "speed-limit-up": uploadLimit,
            
            // Network settings
            "peer-port": peerPort,
            "peer-port-random-on-start": randomPort,
            "port-forwarding-enabled": portForwardingEnabled,
            "pex-enabled": pexEnabled,
            "dht-enabled": dhtEnabled,
            "lpd-enabled": lpdEnabled,
            "utp-enabled": utpEnabled,
            "encryption": encryptionMode,
            
            // Speed settings
            "alt-speed-enabled": altSpeedEnabled,
            "alt-speed-down": altSpeedDown,
            "alt-speed-up": altSpeedUp,
            "alt-speed-time-enabled": altSpeedTimeEnabled,
            "alt-speed-time-begin": altSpeedTimeBegin,
            "alt-speed-time-end": altSpeedTimeEnd,
            "alt-speed-time-day": altSpeedTimeDay
        ]
        
        Task {
            do {
                // Make request
                let (success, _) = try await manager.makeRequest("session-set", arguments: settings)
                
                await MainActor.run {
                    isLoading = false
                    
                    if success {
                        presentationMode.wrappedValue.dismiss()
                    } else {
                        saveError = "Server returned an error"
                        showSaveError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    saveError = error.localizedDescription
                    showSaveError = true
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d", hours, mins)
    }
    
    // Conversion functions for date pickers
    private func updateTimePickersFromMinutes() {
        // Create Date objects for the time pickers
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Convert altSpeedTimeBegin (minutes from midnight) to a Date
        if let beginDate = calendar.date(byAdding: .minute, value: altSpeedTimeBegin, to: today) {
            startTime = beginDate
        }
        
        // Convert altSpeedTimeEnd (minutes from midnight) to a Date
        if let endDate = calendar.date(byAdding: .minute, value: altSpeedTimeEnd, to: today) {
            endTime = endDate
        }
    }
    
    private func updateAltSpeedTimeBegin() {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: startTime)
        altSpeedTimeBegin = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
    
    private func updateAltSpeedTimeEnd() {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: endTime)
        altSpeedTimeEnd = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
    
    private func updateSelectedDaysFromBitfield() {
        // Transmission uses a bit field for days where:
        // bit 0 = Sunday, bit 1 = Monday, etc.
        // The whole field adds up to values like:
        // 127 (1111111) = all days
        // 62 (0111110) = weekdays only
        // etc.
        
        for i in 0..<7 {
            selectedDays[i] = (altSpeedTimeDay & (1 << i)) != 0
        }
    }
    
    private func updateAltSpeedTimeDay() {
        var bitfield = 0
        
        for i in 0..<7 {
            if selectedDays[i] {
                bitfield |= (1 << i)
            }
        }
        
        altSpeedTimeDay = bitfield
    }
}
