import SwiftUI

struct BrowserDataPortabilityContent: View {
#if os(macOS)
    @State private var discoveredArcRecords: [ArcAutofillProfileRecord] = []
    @State private var isShowingArcImport = false
    @State private var arcDiscoveryErrorMessage: String?
#endif
    @State private var autofillStore = BrowserAutofillStore.shared
    let model: BrowserDataPortabilityModel
    let showsMacOSImportRequirement: Bool

    var body: some View {
        Section {
            if showsMacOSImportRequirement {
                BrowserDataPortabilityMacRequirement()
            }
            BrowserDataPortabilityExportControls(model: model)
#if os(macOS)
            Button("Import Arc Addresses…") {
                discoveredArcRecords = []
                guard let userDir = BrowserArcAutofillDiscovery.defaultUserDataDirectory() else {
                    arcDiscoveryErrorMessage = "No Arc installation or profile was discovered on this Mac."
                    isShowingArcImport = true
                    return
                }

                let profiles = BrowserAutofillImportReader.discoverProfileDatabases(in: userDir)
                if profiles.isEmpty {
                    if let defaultURL = BrowserArcAutofillDiscovery.defaultUserDataURL() {
                        do {
                            discoveredArcRecords = try BrowserAutofillImportReader.readProfiles(from: defaultURL)
                            arcDiscoveryErrorMessage = nil
                        } catch {
                            discoveredArcRecords = []
                            arcDiscoveryErrorMessage = "Failed to read Arc database: \(error.localizedDescription)"
                        }
                    } else {
                        arcDiscoveryErrorMessage = "No Arc profiles found."
                    }
                } else {
                    var allRecords: [ArcAutofillProfileRecord] = []
                    for profile in profiles {
                        if let records = try? BrowserAutofillImportReader.readProfiles(from: profile.databaseURL) {
                            allRecords.append(contentsOf: records)
                        }
                    }
                    discoveredArcRecords = allRecords
                    arcDiscoveryErrorMessage = allRecords.isEmpty ? "No autofill records found in discovered profiles." : nil
                }
                isShowingArcImport = true
            }
            .accessibilityIdentifier("import-arc-autofill")
#endif
            BrowserDataPortabilityProgressStatus(model: model)
        } header: {
            Text("Import and export")
        } footer: {
            BrowserDataPortabilityFootnotes()
        }
        #if os(macOS)
        .sheet(isPresented: $isShowingArcImport) {
            BrowserArcAutofillImportSheet(
                browser: model.browser,
                spaceAccess: model.spaceAccess,
                records: discoveredArcRecords,
                discoveryErrorMessage: arcDiscoveryErrorMessage,
                onImport: { spaceID, identities in
                    let token = try model.browser.authorizeAutofillImport(
                        into: spaceID,
                        accessController: model.spaceAccess
                    )
                    try autofillStore.importIdentities(
                        identities,
                        into: spaceID,
                        authorization: token
                    )
                }
            )
        }
#endif
    }
}
