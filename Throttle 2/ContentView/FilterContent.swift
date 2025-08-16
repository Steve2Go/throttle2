import SwiftUI

class FilterViewModel: ObservableObject {
    @AppStorage("showThumbs") var showThumbs: Bool = true
    @AppStorage("sortOption") var sortOption: String = "added"
    @AppStorage("filterOption") var filterOption: String = "all"
    @AppStorage("usePlaylist") var usePlaylist: Bool = false
    func sortImage(for option: String) -> String {
        sortOption == option ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
    }
    
    func filterImage(for option: String) -> String {
        switch option {
        case "all":
            return filterOption == option ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        case "starred":
            return filterOption == option ? "star.fill" : "star"
        default:
            return filterOption == option ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        }
    }
}

struct FilterContent: View {
    @ObservedObject var viewModel: FilterViewModel
    let isSidebar: Bool
    
    var body: some View {
        Group {
            if isSidebar {
                sidebarContent
            } else {
                menuContent
            }
        }
    }
    
    private var sidebarContent: some View {
        Group {
            Section("Media") {
                Button {
                    viewModel.showThumbs.toggle()
                } label: {
                    Label("Thumbnails", systemImage: viewModel.showThumbs ? "photo.badge.checkmark" : "photo.badge.plus")
                }
                .buttonStyle(.plain)
//#if os(iOS)
//            Button {
//                viewModel.usePlaylist.toggle()
//            } label: {
//                Label("Continue Playback", systemImage: viewModel.usePlaylist ? "play" : "play.slash")
//            }
//            .buttonStyle(.plain)
//#endif
            }

            Section("Order") {
                ForEach([("Added", "dateAdded"), ("Activity", "activity"), ("Name", "name")], id: \.1) { title, option in
                    Button {
                        viewModel.sortOption = option
                    } label: {
                        Label(title, systemImage: viewModel.sortImage(for: option))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Section("Filters") {
                ForEach([
                    ("All", "all"),
                    ("Starred", "starred"),
                    ("Downloading", "downloading"),
                    ("Seeding", "seeding"),
                    ("Stopped", "stopped")
                ], id: \.1) { title, option in
                    Button {
                        viewModel.filterOption = viewModel.filterOption != option ? option : ""
                    } label: {
                        Label(title, systemImage: viewModel.filterImage(for: option))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private var menuContent: some View {
        Menu {
            Section("Media") {
                Button {
                    viewModel.showThumbs.toggle()
                } label: {
                    //Image("")
                    Image(systemName: viewModel.showThumbs ? "photo.badge.checkmark" : "photo.badge.plus")
                    Text("Thumbnails")
                        .foregroundColor(.secondary)
                        
                }
                .buttonStyle(.plain)
                
//#if os(iOS)
//            Button {
//                viewModel.usePlaylist.toggle()
//            } label: {
//                Label("Continue Playback", systemImage: viewModel.usePlaylist ? "play" : "play.slash")
//            }
//            .buttonStyle(.plain)
//#endif
            }
            
            
            Section("Order") {
                ForEach([("Added", "dateAdded"), ("Activity", "activity"), ("Name", "name")], id: \.1) { title, option in
                    Button {
                        viewModel.sortOption = option
                    } label: {
                        Image(systemName: viewModel.filterImage(for: option))
                        Text(title)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Section("Filters") {
                ForEach([
                    ("All", "all"),
                    ("Starred", "starred"),
                    ("Downloading", "downloading"),
                    ("Seeding", "seeding"),
                    ("Stopped", "stopped")
                ], id: \.1) { title, option in
                    Button {
                        viewModel.filterOption = viewModel.filterOption != option ? option : ""
                    } label: {
                        Image(systemName: viewModel.filterImage(for: option))
                        Text(title)
                        //Label(title, systemImage: viewModel.filterImage(for: option))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            @AppStorage("filterOption") var filterOption: String = "all"
            #if os(macOS)
            Image(systemName: filterOption == "all" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            #else
            if filterOption == "all" {
                Image(systemName: "line.3.horizontal.decrease")
            } else{
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundColor(.orange)
            }
            
            #endif
        }
    }
}

struct FilterMenu: View {
    @StateObject private var viewModel = FilterViewModel()
    let isSidebar: Bool
    
    var body: some View {
        FilterContent(viewModel: viewModel, isSidebar: isSidebar)
    }
}
