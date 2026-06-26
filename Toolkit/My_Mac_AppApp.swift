//
//  My_Mac_AppApp.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

@main
struct ToolkitApp: App {
    @NSApplicationDelegateAdaptor(ToolkitAppDelegate.self) private var appDelegate
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper)
                .frame(minWidth: 780, minHeight: 540)
                .onAppear {
                    appDelegate.onOpenFiles = { urls in
                        bootstrapper.handleSharedFiles(urls)
                    }
                    appDelegate.onOpenShareURLPaths = { urls in
                        bootstrapper.handleSharedFiles(urls)
                    }
                }
        }
    }
}
