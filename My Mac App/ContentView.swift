//
//  ContentView.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("My Mac App")
                .font(.largeTitle)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    bootstrapper.accessibilityPermissionManager.isTrusted
                        ? "Accessibility Permission Granted"
                        : "Accessibility Permission Required",
                    systemImage: bootstrapper.accessibilityPermissionManager.isTrusted
                        ? "checkmark.shield.fill"
                        : "exclamationmark.shield"
                )
                .foregroundStyle(
                    bootstrapper.accessibilityPermissionManager.isTrusted
                        ? Color.green
                        : Color.orange
                )

                if !bootstrapper.accessibilityPermissionManager.isTrusted {
                    Text("Grant Accessibility permission so app features can detect Dock icons and read active window metadata.")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Request Permission") {
                            bootstrapper.requestAccessibilityAccess()
                        }

                        Button("Open Accessibility Settings") {
                            bootstrapper.accessibilityPermissionManager.openSystemSettings()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Features")
                    .font(.title3)
                    .bold()

                ForEach(bootstrapper.availableFeatures) { feature in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(feature.title)
                                .font(.headline)
                            if feature.requiresAccessibilityAccess {
                                Text("Accessibility")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(feature.summary)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Spacer()
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(bootstrapper: AppBootstrapper())
    }
}
