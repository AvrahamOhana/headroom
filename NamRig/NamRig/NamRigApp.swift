//
//  NamRigApp.swift
//  NamRig
//
//  Created by מיכל אוחנה on 26/06/2026.
//

import SwiftUI

@main
struct NamRigApp: App {
    @AppStorage("uiAppearance") private var uiAppearance = 0   // 0 system · 1 light · 2 dark
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(uiAppearance == 1 ? .light : uiAppearance == 2 ? .dark : nil)
        }
    }
}
