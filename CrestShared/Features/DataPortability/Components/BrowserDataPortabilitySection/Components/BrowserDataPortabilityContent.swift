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
                guard let url = BrowserArcAutofillDiscovery.defaultUserDataURL() else {
                    arcDiscoveryErrorMessage = "No Arc installation or profile was discovered on this Mac."
                    isShowingArcImport = true
                    return
                }
                do {
                    discoveredArcRecords = try BrowserAutofillImportReader.readProfiles(from: url)
                    arcDiscoveryErrorMessage = nil
                } catch {
                    discoveredArcRecords = []
                    arcDiscoveryErrorMessage = "Failed to read Arc database: \(error.localizedDescription)"
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
                    guard let destinationSpace = model.browser.spaceModel(spaceID) else {
                        throw BrowserAutofillStore.AutofillImportAuthorizationError.spaceNotFound
                    }
                    let isLocked = model.spaceAccess.isLocked(destinationSpace)
                    let isPrivate = model.browser.isPrivateBrowsing
                    let token = try BrowserAutofillStore.DestinationAuthorizationToken.issue(
                        for: spaceID,
                        isLocked: isLocked,
                        isPrivate: isPrivate
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
