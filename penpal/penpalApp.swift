//
//  penpalApp.swift
//  penpal
//
//  Created by Anurag singh on 12/07/26.
//

import SwiftUI

@main
struct penpalApp: App {
    /// The welcome introduces the notebook once, without requiring an account.
    @AppStorage("penpal.hasSeenWelcome") private var hasSeenWelcome = false

    var body: some Scene {
        WindowGroup {
            if hasSeenWelcome {
                ContentView()
                    .tint(Pen.inkAccent)
            } else {
                WelcomeView { hasSeenWelcome = true }
                    .tint(Pen.inkAccent)
            }
        }
    }
}
