import SwiftUI

/// Detail and editing sheet for a saved autofill identity.
struct BrowserAutofillIdentityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State var identity: AutofillIdentity
    let onSave: (AutofillIdentity) -> Void
    let onDelete: (UUID) -> Void

    init(
        identity: AutofillIdentity,
        onSave: @escaping (AutofillIdentity) -> Void,
        onDelete: @escaping (UUID) -> Void = { _ in }
    ) {
        _identity = State(initialValue: identity)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Label (e.g. Home, Work)", text: $identity.label)
                    Toggle("Default identity for this Space", isOn: $identity.isDefault)
                }

                Section("Name") {
                    TextField("Full Name", text: $identity.fullName)
                    TextField("First / Given Name", text: $identity.givenName)
                    TextField("Middle Name", text: $identity.middleName)
                    TextField("Last / Family Name", text: $identity.familyName)
                    TextField("Organization / Company", text: $identity.organization)
                }

                Section("Contact") {
                    TextField("Email", text: $identity.email)
                        .textContentType(.emailAddress)
                    TextField("Phone Number", text: $identity.phoneNumber)
                        .textContentType(.telephoneNumber)
                }

                Section("Address") {
                    TextField("Street Address", text: $identity.streetAddress)
                        .textContentType(.streetAddressLine1)
                    TextField("Apt, Suite, Bldg (optional)", text: $identity.addressLine2)
                        .textContentType(.streetAddressLine2)
                    TextField("City", text: $identity.city)
                        .textContentType(.addressCity)
                    TextField("State / Province / Region", text: $identity.stateOrProvince)
                        .textContentType(.addressState)
                    TextField("Postal Code", text: $identity.postalCode)
                        .textContentType(.postalCode)
                    TextField("Country / Region", text: $identity.countryOrRegion)
                        .textContentType(.countryName)
                }

                Section {
                    Button("Delete Identity", role: .destructive) {
                        onDelete(identity.id)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(identity.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(identity)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}
