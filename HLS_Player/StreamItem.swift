//
//  StreamItem.swift
//  HLS_Player
//
//  Created by Zezinas on 2026-04-12.
//

import Foundation
import Combine
import SwiftUI

struct StreamItem: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var creator: String
    var url: String
    var addedAt: Date = Date()
    var thumbnailFilename: String? = nil
    var resumePosition: Double? = nil

    var relativeTime: String {
        let seconds = Date().timeIntervalSince(addedAt)
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 172800 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: addedAt)
    }
}

// ─────────────────────────────────────────────
// MARK: HistoryStore
// ─────────────────────────────────────────────
// Owns the list and handles JSON persistence.
// Saves to the app's Documents folder as history.json.

@MainActor
class HistoryStore: ObservableObject {
    @Published var items: [StreamItem] = []

    private let saveURL: URL = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("history.json")
    }()

    init() { load() }

    func add(_ item: StreamItem) {
        guard !items.contains(where: { $0.url == item.url }) else { return }
        items.insert(item, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        let docsURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        for index in offsets {
            if let filename = items[index].thumbnailFilename {
                try? FileManager.default.removeItem(
                    at: docsURL.appendingPathComponent(filename)
                )
            }
        }
        items.remove(atOffsets: offsets)
        save()
    }

    func update(_ item: StreamItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    func updatePosition(_ seconds: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].resumePosition = seconds
        save()
    }

    func saveThumbnail(_ image: UIImage, for itemID: UUID) {
        let filename = "\(itemID.uuidString).jpg"
        let fileURL  = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)

        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: fileURL)
        }

        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].thumbnailFilename = filename
            save()
        }
    }

    func saveThumbnail(from url: URL, for itemID: UUID) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              items.first(where: { $0.id == itemID })?.thumbnailFilename == nil
        else { return }

        saveThumbnail(image, for: itemID)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([StreamItem].self, from: data)
        else { return }
        items = decoded
    }
}


class SettingsStore: ObservableObject {
    @Published var referer: String {
        didSet { UserDefaults.standard.set(referer, forKey: "referer") }
    }
    @Published var origin: String {
        didSet { UserDefaults.standard.set(origin, forKey: "origin") }
    }
    @Published var resolutionHeight: Double {
        didSet { UserDefaults.standard.set(resolutionHeight, forKey: "resolutionHeight") }
    }
    @Published var peakBitRate: Double {
        didSet { UserDefaults.standard.set(peakBitRate, forKey: "peakBitRate") }
    }

    init() {
        self.referer         = UserDefaults.standard.string(forKey: "referer") ?? "https://www.patreon.com/"
        self.origin          = UserDefaults.standard.string(forKey: "origin")  ?? "https://www.patreon.com/"
        self.resolutionHeight = UserDefaults.standard.double(forKey: "resolutionHeight") // 0 = Auto
        self.peakBitRate      = UserDefaults.standard.double(forKey: "peakBitRate")      // 0 = Auto
    }
}
