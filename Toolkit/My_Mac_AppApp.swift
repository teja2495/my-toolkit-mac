//
//  My_Mac_AppApp.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

@main
struct ToolkitApp: App {
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper)
                .frame(minWidth: 780, minHeight: 540)
        }
    }
}
