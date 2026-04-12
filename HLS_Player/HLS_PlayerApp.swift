//
//  HLS_PlayerApp.swift
//  HLS_Player
//
//  Created by Zezinas on 2026-04-12.
//

import SwiftUI
import AVKit
import AVFAudio

@main
struct HLS_PlayerApp: App {
    init() {
        setupAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

func setupAudioSession() {
    do {
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .moviePlayback,
            options: []
        )
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {
        print("Audio session error:", error)
    }
}
