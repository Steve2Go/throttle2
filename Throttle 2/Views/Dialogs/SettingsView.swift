import SwiftUI

struct SettingsView: View {
    @AppStorage("openDefaultServer") var openDefault: Bool = true
    @AppStorage("pickFiles") var pickFiles: Bool = false
    @AppStorage("pickHttp") var pickHttp: Bool = false
    @AppStorage("allowThumbs") var allowThumbs: Bool = false
    @AppStorage("refreshRate") var refreshRate: Int = 5
    @AppStorage("externalPlayerPrefix") var externalPlayerPrefix: String = "vlc://"
    @AppStorage("externalPlayerAll") var externalPlayerAll: Bool = false
    @ObservedObject var presenting: Presenting
    @Binding var activeSheet: ActiveSheet?
    
    var body: some View {
        HStack (alignment: .top){
#if os(macOS)
            ZStack (alignment: .top, content: {
                content
                HStack {
                    MacCloseButton {
                        activeSheet = nil
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
                    .toolbarBackground(.visible, for: .navigationBar)
            }
#endif
        }
    }
    
    private var content: some View {
        
        Form  {
            
            Section {
                settingRow(
                    title: "Open Default Server",
                    description: "Automatically connect to default server on launch",
                    control: Toggle("", isOn: $openDefault)
                )
                #if os(macOS)
                settingRow(
                    title: "Enable Local File Picking",
                    description: "Allow selecting files using local path",
                    control: Toggle("", isOn: $pickFiles)
                )
                #endif
                settingRow(
                    title: "Enable HTTP File Picking",
                    description: "Allow selecting files from a HTTP server listing",
                    control: Toggle("", isOn: $pickHttp)
                )
                
                settingRow(
                    title: "Allow Thumbnails",
                    description: "Generate and display media thumbnails",
                    control: Toggle("", isOn: $allowThumbs)
                )
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
            } header: {
                Text("Performance")
            }
            #if !os(macOS)
            Section {
                settingRow(
                    title: "Player Prefix",
                    description: "URL scheme for external media player",
                    control: TextField("", text: $externalPlayerPrefix)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .monospaced()
                        #if os(macOS)
                        .frame(width: 200)
                    #else
                        .textInputAutocapitalization(.never)
                        #endif
                )
                settingRow(
                    title: "Presets",
                    description: "Use This Player",
                    control: HStack{
                        Button("VLC"){
                            externalPlayerPrefix = "vlc://"
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote).padding(.trailing, 10)
                        Button("Infuse"){
                            externalPlayerPrefix = "infuse://x-callback-url/play?url="
                        }.buttonStyle(.borderless) .font(.footnote).padding(.trailing, 10)
                        Button("Outplayer"){
                            externalPlayerPrefix = "outplayer://x-callback-url/play?url="
                        }.buttonStyle(.borderless) .font(.footnote).padding(.trailing, 10)
                    }
                )
                
                settingRow(
                    title: "Use External Player for All Files",
                    description: "Open all media files in external player",
                    control: Toggle("", isOn: $externalPlayerAll)
                )
            } header: {
                Text("External Player")
            } footer: {
                Text("Configure how external media players are handled")
                
            }
            #endif
            Spacer()
        }
        #if os(macOS)
        .formStyle(.grouped)
        .padding(.top, 0)
        #endif
        
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
