import SwiftUI

/// Embedded section for managing saved identities and addresses inside the Passwords & Autofill settings pane.
struct BrowserAutofillSection: View {
    let browser: BrowserStore
    let space: SpaceModel
    let spaceAccess: BrowserSpaceAccessController

    @State private var autofillStore = BrowserAutofillStore.shared
    @State private var editingIdentity: AutofillIdentity?

    var body: some View {
        Section {
            let items = autofillStore.identities(in: space.id)

            HStack {
                Button("Add Address or Identity…", systemImage: "plus") {
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
                Text("No saved addresses in this Space")
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
            Text("Crest suggests saved identities when filling contact, shipping, and checkout forms.")
                .crestFormFootnote()
        }
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
}
