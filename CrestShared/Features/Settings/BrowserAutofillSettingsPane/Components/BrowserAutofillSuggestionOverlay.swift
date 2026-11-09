import SwiftUI

/// Anchored native suggestion popover/menu for autofill suggestions directly beneath the focused form field.
/// Adheres strictly to Crest's design system using `crestInteractiveSurface` and Space-aware tinting.
public struct BrowserAutofillSuggestionOverlay: View {
    public let fieldRect: CGRect
    public let identities: [AutofillIdentity]
    public let spaceAccent: Color
    public let onSelect: (AutofillIdentity) -> Void
    public let onDismiss: () -> Void

    @State private var hoveredID: UUID?

    public init(
        fieldRect: CGRect,
        identities: [AutofillIdentity],
        spaceAccent: Color,
        onSelect: @escaping (AutofillIdentity) -> Void,
        onDismiss: @escaping (AutofillIdentity) -> Void = { _ in }
    ) {
        self.fieldRect = fieldRect
        self.identities = identities
        self.spaceAccent = spaceAccent
        self.onSelect = onSelect
        self.onDismiss = { onDismiss(identities.first!) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(identities) { identity in
                Button {
                    onSelect(identity)
                } label: {
                    HStack(spacing: CrestSpacing.small) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(spaceAccent)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(identity.displayName)
                                    .font(CrestTypography.controlTitle)
                                    .foregroundStyle(CrestColor.textPrimary)
                                if identity.isDefault {
                                    Text("Default")
                                        .font(CrestTypography.compactMetadata)
                                        .padding(.horizontal, 4)
                                        .background(CrestColor.fillSubtle)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(identity.addressSummary)
                                .font(CrestTypography.compactMetadata)
                                .foregroundStyle(CrestColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    hoveredID == identity.id
                        ? CrestColor.fillSubtle
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHovered in
                    hoveredID = isHovered ? identity.id : nil
                }
            }
        }
        .padding(4)
        .frame(minWidth: 240, maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CrestColor.chromeMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(CrestColor.separator, lineWidth: 0.5)
        )
    }
}
