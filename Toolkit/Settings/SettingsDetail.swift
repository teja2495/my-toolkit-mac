import SwiftUI

struct SettingsDetail: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    let section: SettingsSection?

    var body: some View {
        Group {
            switch section {
            case .feature(let id):
                featureDetail(id: id)
            case .permissions:
                PermissionsSettingsView(bootstrapper: bootstrapper)
            case .about:
                AboutSettingsView()
            case .none:
                EmptySelectionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DetailBackdrop())
    }

    @ViewBuilder
    private func featureDetail(id: String) -> some View {
        switch id {
        case "corner-notes", "system-health":
            MiscellaneousSettingsView(bootstrapper: bootstrapper)
        case "media-controls":
            MediaControlsSettingsView(bootstrapper: bootstrapper)
        case "dock-window-hover":
            DockWindowHoverSettingsView(bootstrapper: bootstrapper)
        case "phone-integration":
            PhoneIntegrationSettingsView(bootstrapper: bootstrapper)
        case "writing-fix":
            WritingFixSettingsView(bootstrapper: bootstrapper)
        case "text-expander":
            TextExpanderSettingsView(bootstrapper: bootstrapper)
        case "miscellaneous":
            MiscellaneousSettingsView(bootstrapper: bootstrapper)
        default:
            EmptySelectionView()
        }
    }
}

private struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Select a setting")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Choose a feature in the sidebar to configure it.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.9)
            DotGridPattern()
                .opacity(0.35)
        }
        .ignoresSafeArea()
    }
}

private struct DotGridPattern: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let radius: CGFloat = 0.7
            let dotColor = Color.primary.opacity(0.06)

            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}
