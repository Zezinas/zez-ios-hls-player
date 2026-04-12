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
        // Avoid exact duplicate URLs back-to-back
        if items.first?.url != item.url {
            items.insert(item, at: 0)
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func update(_ item: StreamItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
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
