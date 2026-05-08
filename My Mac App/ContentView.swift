//
//  ContentView.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @State private var selection: SettingsSection?

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(bootstrapper: bootstrapper, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            SettingsDetail(bootstrapper: bootstrapper, section: selection)
                .navigationSplitViewColumnWidth(min: 480, ideal: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(.thinMaterial, for: .window)
        .onAppear {
            if selection == nil {
                selection = defaultSelection
            }
        }
    }

    private var defaultSelection: SettingsSection {
        if let firstFeature = bootstrapper.availableFeatures.first {
            return .feature(firstFeature.id)
        }
        return .permissions
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(bootstrapper: AppBootstrapper())
    }
}
