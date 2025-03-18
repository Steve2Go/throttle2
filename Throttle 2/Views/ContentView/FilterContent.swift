//
//  SwiftUIView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//

import SwiftUI

struct FilterMenu: View {
    @ObservedObject var filters: TorrentFilters
    @ObservedObject var store: Store
    
    var body: some View {
        Section ("Filters"){
            Button("Starred", systemImage: filters.current == "starred" ? "star.fill" : "star"){
                filters.current = (filters.current != "starred" ?  "" : "starred")
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button("Downloading", systemImage: filters.current == "downloading" ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"){
                filters.current = (filters.current != "downloading" ?  "" : "downloading")
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button("Seeding", systemImage: filters.current == "seeding" ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"){
                filters.current = (filters.current != "seeding" ?  "" : "seeding")
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button("Stalled", systemImage: filters.current == "stalled" ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"){
                filters.current = (filters.current != "stalled" ?  "" : "stalled")
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
    }
}


struct FilterOrderMenu: View {
    @ObservedObject var store: Store
    @AppStorage("sortOption") var sortOption: String = "dateAdded"
    
    var body: some View {
        Section ("Order"){
            Button("Added", systemImage: sortOption == "added" ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"){
                sortOption = "added"
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button("Activity", systemImage: sortOption == "activity" ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"){
                sortOption = "activity"
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Button("Name", systemImage: sortOption == "name" ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"){
                sortOption = "name"
            }   .buttonStyle(.plain)
                .foregroundColor(.secondary)
            
        }
    }
}
