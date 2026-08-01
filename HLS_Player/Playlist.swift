//
//  Playlist.swift
//  HLS_Player
//

import Foundation
import Combine
import SwiftUI

struct Playlist: Identifiable {
    let id: String
    let name: String
    let fileURL: URL
    let isHistory: Bool
    var items: [StreamItem]
}

@MainActor
class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private var historyURL: URL {
        documentsURL.appendingPathComponent("history.json")
    }

    private var playlistsURL: URL {
        documentsURL.appendingPathComponent("playlists", isDirectory: true)
    }

    init() {
        reload()
    }

    func playlist(id: String) -> Playlist? {
        playlists.first(where: { $0.id == id })
    }

    func reload() {
        var loaded = [Playlist(
            id: "history",
            name: "History",
            fileURL: historyURL,
            isHistory: true,
            items: loadItems(from: historyURL)
        )]

        try? FileManager.default.createDirectory(at: playlistsURL, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: playlistsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
            loaded.append(Playlist(
                id: fileURL.standardizedFileURL.path,
                name: playlistName(from: fileURL),
                fileURL: fileURL,
                isHistory: false,
                items: loadItems(from: fileURL)
            ))
        }

        playlists = loaded.sorted { lhs, rhs in
            lhs.isHistory || (!rhs.isHistory && lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending)
        }
    }

    func addToHistory(_ item: StreamItem) {
        guard let index = playlists.firstIndex(where: \.isHistory),
              !playlists[index].items.contains(where: { $0.url == item.url })
        else { return }
        playlists[index].items.insert(item, at: 0)
        save(playlists[index])
    }

    func update(_ item: StreamItem, in playlistID: String) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == item.id })
        else { return }
        playlists[playlistIndex].items[itemIndex] = item
        save(playlists[playlistIndex])
    }

    func updatePosition(_ seconds: Double, for itemID: UUID, in playlistID: String) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        playlists[playlistIndex].items[itemIndex].resumePosition = seconds
        save(playlists[playlistIndex])
    }

    func delete(itemID: UUID, from playlistID: String) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }

        if let filename = playlists[playlistIndex].items[itemIndex].thumbnailFilename {
            try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(filename))
        }
        playlists[playlistIndex].items.remove(at: itemIndex)
        save(playlists[playlistIndex])
    }

    func saveThumbnail(_ image: UIImage, for itemID: UUID, in playlistID: String) {
        let filename = "\(itemID.uuidString).jpg"
        let fileURL = documentsURL.appendingPathComponent(filename)
        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: fileURL)
        }

        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        playlists[playlistIndex].items[itemIndex].thumbnailFilename = filename
        save(playlists[playlistIndex])
    }

    func saveThumbnail(from url: URL, for itemID: UUID, in playlistID: String) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let playlist = playlist(id: playlistID),
              playlist.items.first(where: { $0.id == itemID })?.thumbnailFilename == nil
        else { return }
        saveThumbnail(image, for: itemID, in: playlistID)
    }

    private func loadItems(from url: URL) -> [StreamItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([StreamItem].self, from: data)
        else { return [] }
        return items
    }

    private func save(_ playlist: Playlist) {
        guard let data = try? JSONEncoder().encode(playlist.items) else { return }
        try? data.write(to: playlist.fileURL, options: .atomic)
    }

    private func playlistName(from fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
