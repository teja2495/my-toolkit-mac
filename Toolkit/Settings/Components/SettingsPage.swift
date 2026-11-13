import SwiftUI

/// Standard settings page: a header with the page's icon, title and description,
/// followed by the page content.
struct SettingsPage<Header: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isActive: Bool?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        isActive: Bool? = nil,
        @ViewBuilder header: @escaping () -> Header = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isActive = isActive
        self.header = header
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(
                    title: title,
                    subtitle: subtitle,
                    systemImage: systemImage,
                    isActive: isActive,
                    trailing: header
                )

                content()

                Spacer(minLength: 24)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .subtleScrollers()
        }
        .scrollContentBackground(.hidden)
    }
}

struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    /// `false` dims the icon to show the feature is off. Status colour lives in the trailing toggle only.
    let isActive: Bool?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isActive == false ? Color.secondary : Color.primary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.settingsSurfaceStrong)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}
