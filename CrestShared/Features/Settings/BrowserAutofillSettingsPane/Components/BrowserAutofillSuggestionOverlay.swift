import SwiftUI

/// Anchored native suggestion popover for autofill suggestions directly beneath the focused form field.
/// Adheres strictly to Crest's design system using `crestInteractiveSurface`, `BrowserCredentialPromptPlacement`,
/// and Space-aware tinting with robust coordinate boundaries and edge clamping.
public struct BrowserAutofillSuggestionOverlay: View {
    public let fieldRect: CGRect
    public let identities: [AutofillIdentity]
    public let spaceAccent: Color
    public let onSelect: (AutofillIdentity) -> Void
    public let onDismiss: () -> Void

    @State private var hoveredID: UUID?
    @State private var selectedIndex: Int = 0
    @State private var containerSize = CGSize.zero
    @State private var promptSize = CGSize.zero

    public init(
        fieldRect: CGRect,
        identities: [AutofillIdentity],
        spaceAccent: Color,
        onSelect: @escaping (AutofillIdentity) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.fieldRect = fieldRect
        self.identities = identities
        self.spaceAccent = spaceAccent
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if identities.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(identities.enumerated()), id: \.element.id) { index, identity in
                    Button {
                        onSelect(identity)
                    } label: {
                        HStack(spacing: CrestSpacing.small) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(spaceAccent)
                                .accessibilityHidden(true)

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
                        (hoveredID == identity.id || selectedIndex == index)
                            ? CrestColor.fillSubtle
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(identity.displayName), \(identity.addressSummary)")
                    .accessibilityHint("Fills this address into the form")
                    .onHover { isHovered in
                        hoveredID = isHovered ? identity.id : nil
                        if isHovered { selectedIndex = index }
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
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                promptSize = size
            }
            .offset(x: clampedPlacement.x, y: clampedPlacement.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                containerSize = size
            }
            .onExitCommand(perform: onDismiss)
            .onKeyPress(.downArrow) {
                if selectedIndex < identities.count - 1 {
                    selectedIndex += 1
                    hoveredID = identities[selectedIndex].id
                }
                return .handled
            }
            .onKeyPress(.upArrow) {
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    hoveredID = identities[selectedIndex].id
                }
                return .handled
            }
            .onKeyPress(.return) {
                if selectedIndex >= 0 && selectedIndex < identities.count {
                    onSelect(identities[selectedIndex])
                }
                return .handled
            }
        }
    }

    private var clampedPlacement: CGPoint {
        let width = promptSize.width > 0 ? promptSize.width : 260
        let height = promptSize.height > 0 ? promptSize.height : 120

        var x = fieldRect.minX
        if containerSize.width > 0 && x + width > containerSize.width - 12 {
            x = max(12, containerSize.width - width - 12)
        }
        x = max(12, x)

        var y = fieldRect.maxY + 4
        if containerSize.height > 0 && y + height > containerSize.height - 12 {
            // Flip above field if overflowing bottom container boundary
            y = max(12, fieldRect.minY - height - 4)
        }
        return CGPoint(x: x, y: y)
    }
}
