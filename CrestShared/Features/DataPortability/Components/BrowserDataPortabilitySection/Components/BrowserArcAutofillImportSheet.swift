#if os(macOS)
import SwiftUI

/// Sheet for previewing and importing discovered Arc Browser identities into a selected Space.
public struct BrowserArcAutofillImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let browser: BrowserStore
    let spaceAccess: BrowserSpaceAccessController
    let records: [ArcAutofillProfileRecord]
    let onImport: (UUID, [AutofillIdentity]) throws -> Void

    @State private var selectedSpaceID: UUID?
    @State private var importErrorMessage: String?

    /// Filters available destination Spaces to only those that are unlocked and persistent.
    private var eligibleSpaces: [SpaceModel] {
        browser.spaceModels.filter { space in
            !spaceAccess.isLocked(space) && !browser.isPrivateBrowsing
        }
    }

    public init(
        browser: BrowserStore,
        spaceAccess: BrowserSpaceAccessController,
        records: [ArcAutofillProfileRecord],
        onImport: @escaping (UUID, [AutofillIdentity]) throws -> Void
    ) {
        self.browser = browser
        self.spaceAccess = spaceAccess
        self.records = records
        self.onImport = onImport
        let defaultSpace = browser.shownSpace.flatMap { !spaceAccess.isLocked($0) ? $0.id : nil }
            ?? browser.spaceModels.first(where: { !spaceAccess.isLocked($0) })?.id
        _selectedSpaceID = State(initialValue: defaultSpace)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let importErrorMessage {
                    Section {
                        Text(importErrorMessage)
                            .foregroundStyle(CrestColor.danger)
                            .font(CrestTypography.controlTitle)
                    }
                }
                Section {
                    CrestSpaceMenuPicker(
                        "Destination Space",
                        selection: $selectedSpaceID,
                        spaces: CrestSpaceIdentity.list(eligibleSpaces)
                    )
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Addresses will be saved exclusively inside this Space.")
                        .crestFormFootnote()
                }

                Section("Discovered Arc Profiles (\(records.count))") {
                    ForEach(records, id: \.guid) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.fullName.isEmpty ? "Unnamed Profile" : record.fullName)
                                .font(CrestTypography.controlTitle)

                            if !record.email.isEmpty {
                                Text(record.email)
                                    .font(CrestTypography.metadata)
                                    .foregroundStyle(CrestColor.textSecondary)
                            }

                            let addressParts = [record.streetAddress, record.city, record.state, record.zipcode, record.countryCode]
                                .filter { !$0.isEmpty }
                            if !addressParts.isEmpty {
                                Text(addressParts.joined(separator: ", "))
                                    .font(CrestTypography.compactMetadata)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import Arc Addresses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        guard let spaceID = selectedSpaceID else { return }
                        let identities = records.map { record in
                            AutofillIdentity(
                                spaceID: spaceID,
                                label: record.fullName.isEmpty ? "Arc Address" : record.fullName,
                                fullName: record.fullName,
                                organization: record.companyName,
                                email: record.email,
                                phoneNumber: record.phoneNumber,
                                streetAddress: record.streetAddress,
                                city: record.city,
                                stateOrProvince: record.state,
                                postalCode: record.zipcode,
                                countryOrRegion: record.countryCode
                            )
                        }
                        do {
                            try onImport(spaceID, identities)
                            dismiss()
                        } catch {
                            importErrorMessage = "Destination Space is locked or unavailable: \(error.localizedDescription)"
                        }
                    }
                    .disabled(selectedSpaceID == nil || records.isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }
}

#endif
