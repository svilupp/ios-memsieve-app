//
//  MemSieveApp.swift
//  MemSieve
//
//  Created by Jan Siml on 07/12/2024.
//

import SwiftUI

@main
struct MemSieveApp: App {
    @StateObject private var model = AppModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    print("📱 App received URL: \(url)")
                    model.handleIncomingURL(url)
                }
        }
    }
}
