//
//  penpalApp.swift
//  penpal
//
//  Created by Anurag singh on 12/07/26.
//

import SwiftUI

@main
struct penpalApp: App {
    /// The welcome page shows once; any choice on it (Google or guest)
    /// dismisses it for good. Auth state itself lives in AuthStub until the
    /// real Google SDK replaces it.
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
