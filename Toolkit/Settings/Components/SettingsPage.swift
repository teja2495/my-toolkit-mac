import SwiftUI

struct SettingsPage<Header: View, Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder header: @escaping () -> Header = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.header = header
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: eyebrow)
                        Spacer()
                        header()
                    }

                    Text(title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.primary)
                        .tracking(-0.4)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 32)

                content()

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
