import SwiftUI

/// The native suggestion panel floating under the focused form field.
///
/// It carries Crest's own flyout surface, sits against the field the page
/// reported — zoom-corrected by the shell that hosts it — and asks two
/// questions: put the whole identity in, or only the field being typed in.
public struct BrowserAutofillSuggestionOverlay: View {
    /// Where the focused field sits over the page, in this shell's points.
    public let fieldRect: CGRect
    public let identities: [AutofillIdentity]
    public let spaceAccent: Color
    public let onSelectionBegan: () -> Void
    /// Puts the whole identity into every visible, eligible field of the section.
    public let onFillAll: (AutofillIdentity) -> Void
    /// Puts the identity into the one field the user was last focused on.
    public let onFillFieldOnly: (AutofillIdentity) -> Void
    public let onDismiss: () -> Void

    /// The gap the panel keeps under the field it anchors to, and the page
    /// inset it never crosses on its way back into view.
    private static let fieldAnchorGap: CGFloat = 4
    private static let edgeInset: CGFloat = 12

    @State private var hoveredID: UUID?
    @State private var selectedIndex: Int = 0
    @State private var containerSize = CGSize.zero
    @State private var promptSize = CGSize.zero

    public init(
        fieldRect: CGRect,
        identities: [AutofillIdentity],
        spaceAccent: Color,
        onSelectionBegan: @escaping () -> Void = {},
        onFillAll: @escaping (AutofillIdentity) -> Void,
        onFillFieldOnly: @escaping (AutofillIdentity) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.fieldRect = fieldRect
        self.identities = identities
        self.spaceAccent = spaceAccent
        self.onSelectionBegan = onSelectionBegan
        self.onFillAll = onFillAll
        self.onFillFieldOnly = onFillFieldOnly
        self.onDismiss = onDismiss
    }

    /// Kept for the shell call sites that predate fill scopes: selecting an
    /// identity fills all the section's fields.
    public init(
        fieldRect: CGRect,
        identities: [AutofillIdentity],
        spaceAccent: Color,
        onSelectionBegan: @escaping () -> Void = {},
        onSelect: @escaping (AutofillIdentity) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.init(
            fieldRect: fieldRect,
            identities: identities,
            spaceAccent: spaceAccent,
            onSelectionBegan: onSelectionBegan,
            onFillAll: onSelect,
            onFillFieldOnly: { _ in },
            onDismiss: onDismiss
        )
    }

    public var body: some View {
        if identities.isEmpty {
            EmptyView()
        } else {
            panel
                .animation(reduceMotion ? nil : CrestMotion.step, value: selectedIndex)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panel: some View {
        let placement = BrowserCredentialPromptPlacement(
            field: fieldRect,
            size: promptSize,
            container: containerSize,
            gap: BrowserAutofillSuggestionOverlay.fieldAnchorGap,
            inset: BrowserAutofillSuggestionOverlay.edgeInset
        )
        return VStack(alignment: .leading, spacing: 0) {
            rows
            Divider().padding(.vertical, 2)
            footer(index: selectedIndex)
        }
        .padding(6)
        .frame(minWidth: 260, maxWidth: 320)
        .crestFloatingFlyoutStyle(
            in: RoundedRectangle(cornerRadius: CrestRadius.compact, style: .continuous)
        )
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            promptSize = size
        }
        // Held back for the frame it takes to measure the page and the panel,
        // so the panel is never seen in the corner it is measured in on its
        // way to the field.
        .opacity(isMeasured ? 1 : 0)
        .transition(
            .scale(scale: 0.96, anchor: placement.isAboveField ? .bottom : .top)
                .combined(with: .opacity)
        )
        .offset(x: placement.origin.x, y: placement.origin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            containerSize = size
        }
        #if os(macOS)
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
                fillSelected(.allFields)
                return .handled
            }
            .onKeyPress(.tab) {
                if selectedIndex >= 0 && selectedIndex < identities.count {
                    fillSelected(.focusedField)
                }
                return .handled
            }
        #endif
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(identities.enumerated()), id: \.element.id) { index, identity in
                row(for: identity, index: index)
            }
        }
    }

    private func row(for identity: AutofillIdentity, index: Int) -> some View {
        Button {
            fillSelected(.allFields)
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
                                .background(CrestColor.selection)
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    onSelectionBegan()
                }
                .onEnded { value in
                    // If dragged away from the button surface, cancel selection hold
                    let isOutside =
                        value.translation.width > 100 || value.translation.width < -100
                        || value.translation.height > 60 || value.translation.height < -60
                    if isOutside {
                        onDismiss()
                    }
                }
        )
        .background(
            (hoveredID == identity.id || selectedIndex == index)
                ? CrestColor.selection
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

    /// The two fill scopes, on the identity the selection rests on.
    private func footer(index: Int) -> some View {
        let identity = identities.indices.contains(index) ? identities[index] : identities[0]
        return HStack(spacing: CrestSpacing.small) {
            Button {
                onFillFieldOnly(identity)
            } label: {
                Label("This field only", systemImage: "text.cursor")
                    .font(CrestTypography.compactMetadata)
            }
            .buttonStyle(.crestSecondary)
            .controlSize(.small)

            Spacer()

            Button {
                onFillAll(identity)
            } label: {
                Label("Autofill all", systemImage: "arrow.down.doc.fill")
                    .font(CrestTypography.compactMetadata)
            }
            .buttonStyle(.crestPrimary)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func fillSelected(_ scope: BrowserAutofillSession.FillScope) {
        guard identities.indices.contains(selectedIndex) else { return }
        let identity = identities[selectedIndex]
        switch scope {
        case .allFields:
            onFillAll(identity)
        case .focusedField:
            onFillFieldOnly(identity)
        }
    }

    private var isMeasured: Bool {
        containerSize.width > 0 && promptSize.width > 0
    }
}
