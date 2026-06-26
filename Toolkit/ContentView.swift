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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SidebarBackdrop())
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                }
        } detail: {
            SettingsDetail(bootstrapper: bootstrapper, section: selection)
                .navigationSplitViewColumnWidth(min: 480, ideal: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(.regularMaterial, for: .window)
        .onAppear {
            if selection == nil {
                selection = defaultSelection
            }
        }
    }

    private var defaultSelection: SettingsSection {
        if bootstrapper.availableFeatures.contains(where: { $0.id == "phone-integration" }) {
            return .feature("phone-integration")
        }
        if let firstFeature = bootstrapper.availableFeatures.first {
            return .feature(firstFeature.id)
        }
        return .permissions
    }
}

private struct SidebarBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(0.92)
            .ignoresSafeArea()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(bootstrapper: AppBootstrapper())
    }
}
