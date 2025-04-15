import SwiftUI

struct SettingsView: View {
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    @AppStorage("openDefaultServer") var openDefault: Bool = true
    @AppStorage("pickFiles") var pickFiles: Bool = false
    @AppStorage("pickHttp") var pickHttp: Bool = false
    @AppStorage("mountOnStart") var mountOnStart: Bool = true
    @AppStorage("unmountOnClose") var unmountOnClose: Bool = false
    @AppStorage("refreshRate") var refreshRate: Int = 5
    @AppStorage("externalPlayerPrefix") var externalPlayerPrefix: String = "vlc://"
    @AppStorage("externalPlayerAll") var externalPlayerAll: Bool = false
    @AppStorage("showThumbs") var showThumbs: Bool = false
    @AppStorage("preferVLC") var preferVLC: Bool = false
    @AppStorage("usePlaylist") var usePlaylist: Bool = false
    @AppStorage("waitPlaylist") var waitPlaylist: Int = 5
    @AppStorage("primaryFile") var primaryFiles: Bool = false
    @AppStorage("deleteOnSuccess") var deleteOnSuccess: Bool = true
    @AppStorage("qlVideo") var qlVideo: Bool = false
    @ObservedObject var presenting: Presenting
    @State var installerView = false
    @Environment(\.openURL) private var openURL
    
    func isVLCInstalled() -> Bool {
            #if os(iOS)
            // Use a simple vlc:// URL to test if VLC is installed
            guard let vlcUrl = URL(string: "vlc://") else { return false }
            return UIApplication.shared.canOpenURL(vlcUrl)
            #else
            // For macOS, you might want to check differently or always return true
            return true
            #endif
        }
    var body: some View {
        HStack (alignment: .top){
#if os(macOS)
            ZStack (alignment: .top, content: {
                content
                HStack {
                    MacCloseButton {
                        presenting.activeSheet = nil
                    }.padding([.top, .leading], 9).padding(.bottom, 0)
                    Spacer()
                }
            })
            
            //.frame(minWidth: 500, minHeight: 400)
            //.padding()
#else
            NavigationStack {
                content
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbarBackground(.hidden)
            }

#endif
        }
    }
    
    private var content: some View {
        
        Form  {
            
            Section {
                settingRow(
                    title: "Sync servers with iCloud",
                    description: "Synchronize server settings across devices. Restart Required.",
                    control: Toggle("", isOn: $useCloudKit)
                )
                settingRow(
                    title: openDefault ? "Opening Default Server" : "Opening Last Used Server",
                    description: "Automatically connect to server on launch",
                    control: Toggle("", isOn: $openDefault)
                )
                settingRow(
                    title: "Delete Torrents",
                    description: ".torrent deletion after a sucessful upload",
                    control: Toggle("", isOn: $deleteOnSuccess)
                )
                settingRow(
                    title: "Show Thumbnails in List",
                    description: "Show thumbnails in Torrent List when available",
                    control: Toggle("", isOn: $showThumbs)
                )
//                #if os(iOS)
//                settingRow(
//                    title: "Continue Playback",
//                    description: "Offer to play the next video file after playback",
//                    control: Toggle("", isOn: $usePlaylist)
//                )
//                if usePlaylist {
//                    settingRow(
//                        title: "Playback wait time",
//                        description: "How long to play or cancel the next video file",
//                        control: HStack {
//                            Text("\(waitPlaylist) seconds")
//                                .frame(minWidth: 80, alignment: .trailing)
//                            Stepper("", value: $waitPlaylist, in: 1...60)
//                        }
//                    )
//                }
//#endif
//                #if os(iOS)
//                if isVLCInstalled() {
//                    settingRow(
//                        title: "Prefer VLC Player",
//                        description: "Use VLC in preference to internal player",
//                        control: Toggle("", isOn: $preferVLC)
//                    )
//                }
//#endif
                #if os(macOS)
                settingRow(
                    title: "Mount SFTP on Launch",
                    description: "Mount SFTP on launch learn more here",
                    control: Toggle("", isOn: $mountOnStart)
                )
               
#else
//            settingRow(
//                title: primaryFiles ?  "Primary Action is Files" : "Primary Action is Details",
//                    description: "Swtch between opening files and opening files as primaey action",
//                    control: Toggle("", isOn: $primaryFiles)
//                )
                #endif
            } header: {
                Text("General")
            } footer: {
                Text("These settings affect the general behavior of the app")
            }.padding(.top, 5)
            
            Section {
                settingRow(
                    title: "Refresh Rate",
                    description: "How often the content is updated",
                    control: HStack {
                        Text("\(refreshRate) seconds")
                            .frame(minWidth: 80, alignment: .trailing)
                        Stepper("", value: $refreshRate, in: 1...60)
                    }
                )
//                #if os(macOS)
//                settingRow(
//                    title: "Use system generated thumbnails for all video",
//                    description: "Reccomended if you have QL Video installed.",
//                    control: Toggle("", isOn: $qlVideo)
//                )
////                VStack{
////                    HStack{
////                        Button("Get QL Video") {
////                            openURL(URL(string:"https://github.com/Marginal/QLVideo/releases/latest")!)
////                        }
////                        Text("Enables video thumnails in Finder & improves Throttle thumbnails")
////                    }
////                    Text("Restart you Mac then clear cache below after installation.").font(.caption)
////                }
//#endif
                
                    Button("Clear Cache (Restart Required)"){
                        ThumbnailManager.shared.clearCache()
                    }
                   
              
                
                
            } header: {
                Text("Performance")
            }
            
            //Spacer()
            Section {
                #if os(macOS)
                
                Text("Fuse-t and sshfs are bundled for SFTP. Click below for Installation").font(.caption)
                Button("Install Dependencies") {
                    installerView.toggle()
                }
                #else
                Text("FFMpeg is used for superior server - side thumbnail generation. Click below for Installation").font(.caption)
                Button("Install Dependencies") {
                    installerView.toggle()
                }
                #endif
                
                Text("In app icons via SF Icons and https://icons8.com.").font(.caption)
                Text("App icon based on icon from https://www.iconarchive.com/").font(.caption)
            }header: {
                Text("About")
            }
            
        }
       
        .formStyle(.grouped)
        .padding(.top, 0)
        .sheet(isPresented: $installerView){
#if os(macOS)
            InstallerView()
                .frame(width: 500, height: 500)
            #else
            if ServerManager.shared.selectedServer != nil {
                DependencyInstallerView(server: ServerManager.shared.selectedServer!)
            } else {
                Text("Please select a server first.")
            }
#endif
        }
       
        
    }
    
    private func settingRow<Control: View>(
        title: String,
        description: String,
        control: Control
    ) -> some View {
        #if os(macOS)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            control
                .labelsHidden()
        }
        .padding(.vertical, 4)
        #else
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                control
                    .labelsHidden()
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.gray)
        }



        #endif
    }
}

//#Preview("iOS") {
//    SettingsView()
//}
//
//#Preview("macOS") {
//    SettingsView()
//}
