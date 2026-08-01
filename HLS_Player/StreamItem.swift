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
    var password: String? = nil
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
