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
                                .foregroundStyle(space.settings.look.primaryColor.color)

                            VStack(alignment: .leading, spacing: CrestFormRowMetrics.titleSpacing) {
                                HStack(spacing: CrestSpacing.small) {
                                    Text(identity.label)
                                        .font(CrestTypography.controlTitle)
                                    if identity.isDefault {
                                        Text("Default")
                                            .font(CrestTypography.compactMetadata)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(CrestColor.selection)
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
                                do { try autofillStore.save(copy) } catch {}
                            }
                        }
                        Divider()
                        Button("Delete Identity", systemImage: "trash", role: .destructive) {
                            do { try autofillStore.delete(identity.id) } catch {}
                        }
                    }
                }
            }
        } header: {
            Text("Addresses & Identities")
        } footer: {
            VStack(alignment: .leading, spacing: CrestFormRowMetrics.titleSpacing) {
                if let failure = autofillStore.writeFailureMessage ?? autofillStore.loadFailureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .crestFormFootnote()
                }
                Text("Crest suggests saved identities when filling contact, shipping, and checkout forms.")
                    .crestFormFootnote()
            }
        }
        .sheet(item: $editingIdentity) { identity in
            BrowserAutofillIdentityDetailView(
                identity: identity,
                onSave: { updated in
                    do { try autofillStore.save(updated) } catch {}
                },
                onDelete: { id in
                    do { try autofillStore.delete(id) } catch {}
                }
            )
        }
    }
}
