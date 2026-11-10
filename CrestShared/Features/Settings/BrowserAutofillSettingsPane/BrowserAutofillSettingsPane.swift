import SwiftUI

/// Space-scoped autofill identity and address management pane in Settings.
struct BrowserAutofillSettingsPane: View {
    let browser: BrowserStore
    let spaceAccess: BrowserSpaceAccessController
    let fixedSpaceID: UUID?

    @State private var autofillStore = BrowserAutofillStore.shared
    @State private var pickedSpaceID: UUID?
    @State private var editingIdentity: AutofillIdentity?
    @State private var isCreatingIdentity = false
    @State private var searchText = ""

    private var selectedSpaceID: UUID? { fixedSpaceID ?? pickedSpaceID }
    private var selectedSpaceBinding: Binding<UUID?> {
        Binding(get: { selectedSpaceID }, set: { if fixedSpaceID == nil { pickedSpaceID = $0 } })
    }

    init(
        browser: BrowserStore,
        spaceAccess: BrowserSpaceAccessController,
        fixedSpaceID: UUID? = nil
    ) {
        self.browser = browser
        self.spaceAccess = spaceAccess
        self.fixedSpaceID = fixedSpaceID
    }

    var body: some View {
        BrowserSettingsPane(.passwords) {
            spacePickerSection
            if let space {
                if canRevealSpaceData {
                    identitiesSection(for: space)
                } else {
                    BrowserSettingsPrivateSpaceAccessSection(
                        space: space,
                        accessController: spaceAccess,
                        detail: "Unlock this Space to view and edit saved addresses and contact details."
                    )
                }
            }
        }
        .crestRepairsSpaceSelection(selectedSpaceBinding, in: browser)
        .sheet(item: $editingIdentity) { identity in
            BrowserAutofillIdentityDetailView(
                identity: identity,
                onSave: { updated in
                    autofillStore.save(updated)
                },
                onDelete: { id in
                    autofillStore.delete(id)
                }
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var spacePickerSection: some View {
        if fixedSpaceID == nil {
            Section {
                CrestSpaceMenuPicker(
                    "Space",
                    selection: selectedSpaceBinding,
                    spaces: CrestSpaceIdentity.list(browser.spaceModels)
                )
            }
        }
    }

    @ViewBuilder
    private func identitiesSection(for space: SpaceModel) -> some View {
        let items = filteredIdentities(in: space.id)

        Section {
            HStack {
                Button("Add Identity…", systemImage: "plus") {
                    let newIdentity = AutofillIdentity(
                        spaceID: space.id,
                        label: items.isEmpty ? "Home" : "Address \(items.count + 1)"
                    )
                    editingIdentity = newIdentity
                }
                .accessibilityIdentifier("add-autofill-identity")
                Spacer()
            }

            if items.isEmpty {
                Text(searchText.isEmpty ? "No saved identities in this Space" : "No matching identities")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { identity in
                    Button {
                        editingIdentity = identity
                    } label: {
                        HStack(spacing: CrestSpacing.medium) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(space.accent.tint.color)

                            VStack(alignment: .leading, spacing: CrestFormRowMetrics.titleSpacing) {
                                HStack(spacing: CrestSpacing.small) {
                                    Text(identity.label)
                                        .font(CrestTypography.controlTitle)
                                    if identity.isDefault {
                                        Text("Default")
                                            .font(CrestTypography.compactMetadata)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(CrestColor.fillSubtle)
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(identity.displayName)
                                    .font(CrestTypography.metadata)
                                    .foregroundStyle(CrestColor.textSecondary)

                                Text(identity.addressSummary)
                                    .font(CrestTypography.compactMetadata)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Identity…", systemImage: "pencil") {
                            editingIdentity = identity
                        }
                        if !identity.isDefault {
                            Button("Set as Default", systemImage: "star") {
                                var copy = identity
                                copy.isDefault = true
                                autofillStore.save(copy)
                            }
                        }
                        Divider()
                        Button("Delete Identity", systemImage: "trash", role: .destructive) {
                            autofillStore.delete(identity.id)
                        }
                    }
                }
            }
        } header: {
            Text("Addresses & Identities")
        } footer: {
            Text("Crest suggests saved identities when filling contact and shipping forms.")
                .crestFormFootnote()
        }
    }

    // MARK: - Derived state

    private var space: SpaceModel? {
        guard let selectedSpaceID else { return nil }
        return browser.spaceModel(selectedSpaceID)
    }

    private var canRevealSpaceData: Bool {
        guard let space else { return false }
        return !spaceAccess.isLocked(space)
    }

    private func filteredIdentities(in spaceID: UUID) -> [AutofillIdentity] {
        autofillStore.identities(in: spaceID, matching: searchText)
    }
}
