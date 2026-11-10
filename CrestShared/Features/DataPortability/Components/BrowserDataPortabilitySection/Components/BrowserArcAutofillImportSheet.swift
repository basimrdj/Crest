#if os(macOS)
import SwiftUI

/// Sheet for previewing and importing discovered Arc Browser identities into a selected Space.
public struct BrowserArcAutofillImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let browser: BrowserStore
    let records: [ArcAutofillProfileRecord]
    let onImport: (UUID, [AutofillIdentity]) -> Void

    @State private var selectedSpaceID: UUID?

    public init(
        browser: BrowserStore,
        records: [ArcAutofillProfileRecord],
        onImport: @escaping (UUID, [AutofillIdentity]) -> Void
    ) {
        self.browser = browser
        self.records = records
        self.onImport = onImport
        _selectedSpaceID = State(initialValue: browser.shownSpace?.id ?? browser.spaceModels.first?.id)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    CrestSpaceMenuPicker(
                        "Destination Space",
                        selection: $selectedSpaceID,
                        spaces: CrestSpaceIdentity.list(browser.spaceModels)
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
                        onImport(spaceID, identities)
                        dismiss()
                    }
                    .disabled(selectedSpaceID == nil || records.isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }
}

#endif
