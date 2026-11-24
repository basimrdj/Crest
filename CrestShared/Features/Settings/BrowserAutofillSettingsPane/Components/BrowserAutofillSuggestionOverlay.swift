import SwiftUI

/// The native suggestion panel floating under the focused form field.
///
/// It carries Crest's own flyout surface, sits against the field the page
/// reported — zoom-corrected by the shell that hosts it — and shows the values
/// the focused field can take: a name field lists names, an email field lists
/// emails. Choosing one fills that field; the footer can fill the identity's
/// whole section instead.
public struct BrowserAutofillSuggestionOverlay: View {
    /// Where the focused field sits over the page, in this shell's points.
    public let fieldRect: CGRect
    /// The values the focused field can take, one per identity.
    public let suggestions: [(identity: AutofillIdentity, value: String)]
    /// What the focused field is called, for the header: "Full name".
    public let fieldLabel: String?
    public let spaceAccent: Color
    public let onSelectionBegan: () -> Void
    /// Puts the selected value into the one field the user was last focused on.
    public let onFillFieldOnly: (AutofillIdentity) -> Void
    /// Puts the whole identity into every visible, eligible field of the section.
    public let onFillAll: (AutofillIdentity) -> Void
    public let onDismiss: () -> Void

    @State private var hoveredID: UUID?
    @State private var selectedIndex: Int = 0
    @State private var containerSize = CGSize.zero
    @State private var promptSize = CGSize.zero

    /// The gap the panel keeps under the field it anchors to, and the page
    /// inset it never crosses on its way back into view.
    private static let fieldAnchorGap: CGFloat = 4
    private static let edgeInset: CGFloat = 12

    public init(
        fieldRect: CGRect,
        suggestions: [(identity: AutofillIdentity, value: String)],
        fieldLabel: String? = nil,
        spaceAccent: Color,
        onSelectionBegan: @escaping () -> Void = {},
        onFillFieldOnly: @escaping (AutofillIdentity) -> Void,
        onFillAll: @escaping (AutofillIdentity) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.fieldRect = fieldRect
        self.suggestions = suggestions
        self.fieldLabel = fieldLabel
        self.spaceAccent = spaceAccent
        self.onSelectionBegan = onSelectionBegan
        self.onFillFieldOnly = onFillFieldOnly
        self.onFillAll = onFillAll
        self.onDismiss = onDismiss
    }

    /// Kept for the call sites and tests that predate per-field suggestions:
    /// one row per identity, showing the identity itself.
    public init(
        fieldRect: CGRect,
        identities: [AutofillIdentity],
        spaceAccent: Color,
        onSelectionBegan: @escaping () -> Void = {},
        onSelect: @escaping (AutofillIdentity) -> Void,
        onFillFieldOnly: @escaping (AutofillIdentity) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.init(
            fieldRect: fieldRect,
            suggestions: identities.map { ($0, $0.resolvedFullName) },
            fieldLabel: nil,
            spaceAccent: spaceAccent,
            onSelectionBegan: onSelectionBegan,
            onFillFieldOnly: onFillFieldOnly,
            onFillAll: onSelect,
            onDismiss: onDismiss
        )
    }

    public var body: some View {
        if suggestions.isEmpty {
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
            if let fieldLabel {
                Text("Fill \(fieldLabel)…")
                    .font(CrestTypography.compactMetadata)
                    .foregroundStyle(CrestColor.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
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
                if selectedIndex < suggestions.count - 1 {
                    selectedIndex += 1
                    hoveredID = suggestions[selectedIndex].identity.id
                }
                return .handled
            }
            .onKeyPress(.upArrow) {
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    hoveredID = suggestions[selectedIndex].identity.id
                }
                return .handled
            }
            .onKeyPress(.return) {
                fillSelected(.focusedField)
                return .handled
            }
        #endif
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(
                Array(suggestions.enumerated()),
                id: \.element.identity.id
            ) { index, suggestion in
                row(for: suggestion, index: index)
            }
        }
    }

    private func row(
        for suggestion: (identity: AutofillIdentity, value: String),
        index: Int
    ) -> some View {
        Button {
            fillSelected(.focusedField)
        } label: {
            HStack(spacing: CrestSpacing.small) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.subheadline)
                    .foregroundStyle(spaceAccent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.value)
                        .font(CrestTypography.controlTitle)
                        .foregroundStyle(CrestColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(suggestion.identity.displayName)
                            .font(CrestTypography.compactMetadata)
                            .foregroundStyle(CrestColor.textSecondary)
                            .lineLimit(1)
                        if suggestion.identity.isDefault {
                            Text("Default")
                                .font(CrestTypography.compactMetadata)
                                .padding(.horizontal, 4)
                                .background(CrestColor.selection)
                                .clipShape(Capsule())
                        }
                    }
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
            (hoveredID == suggestion.identity.id || selectedIndex == index)
                ? CrestColor.selection
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(suggestion.value), from \(suggestion.identity.displayName)")
        .accessibilityHint("Fills this value into the field")
        .onHover { isHovered in
            hoveredID = isHovered ? suggestion.identity.id : nil
            if isHovered { selectedIndex = index }
        }
    }

    /// The two fill scopes, on the suggestion the selection rests on.
    private func footer(index: Int) -> some View {
        let selected = suggestions.indices.contains(index) ? suggestions[index] : suggestions[0]
        return HStack(spacing: CrestSpacing.small) {
            Button {
                onFillFieldOnly(selected.identity)
            } label: {
                Label("This field only", systemImage: "character.cursor.ibeam")
                    .font(CrestTypography.compactMetadata)
            }
            .buttonStyle(.crestSecondary)
            .controlSize(.small)

            Spacer()

            Button {
                onFillAll(selected.identity)
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
        guard suggestions.indices.contains(selectedIndex) else { return }
        let identity = suggestions[selectedIndex].identity
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
