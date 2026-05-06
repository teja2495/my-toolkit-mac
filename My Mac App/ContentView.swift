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
            HStack(spacing: 10) {
                Text("My Mac App")
                    .font(.largeTitle)
                    .bold()

                Spacer()

                Button {
                    guard !bootstrapper.accessibilityPermissionManager.isTrusted else { return }
                    bootstrapper.requestAccessibilityAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.fill")
                            .foregroundStyle(
                                bootstrapper.accessibilityPermissionManager.isTrusted
                                    ? Color.green
                                    : Color.orange
                            )
                        if !bootstrapper.accessibilityPermissionManager.isTrusted {
                            Text("Grant Permission")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(
                    bootstrapper.accessibilityPermissionManager.isTrusted
                        ? "Accessibility permission granted"
                        : "Grant accessibility permission"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Features")
                    .font(.title3)
                    .bold()

                ForEach(bootstrapper.availableFeatures) { feature in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.summary)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(isOn: Binding(
                                get: { feature.isEnabled },
                                set: { _ in bootstrapper.toggleFeature(id: feature.id) }
                            )) {
                                EmptyView()
                            }
                            .toggleStyle(.switch)
                            .disabled(!bootstrapper.accessibilityPermissionManager.isTrusted && feature.requiresAccessibilityAccess)
                        }

                        if feature.id == "dock-window-hover", feature.isEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Popup delay")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int((bootstrapper.dockHoverPopupDelay * 1000).rounded())) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                Slider(
                                    value: $bootstrapper.dockHoverPopupDelay,
                                    in: 0...1.5,
                                    step: 0.05
                                )
                            }
                            .padding(.top, 8)
                        }
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
