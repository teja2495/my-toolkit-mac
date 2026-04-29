//
//  My_Mac_AppApp.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

@main
struct My_Mac_AppApp: App {
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
