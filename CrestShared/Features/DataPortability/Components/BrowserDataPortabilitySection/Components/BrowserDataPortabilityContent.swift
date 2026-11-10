import SwiftUI

struct BrowserDataPortabilityContent: View {
#if os(macOS)
    @State private var discoveredArcRecords: [ArcAutofillProfileRecord] = []
    @State private var isShowingArcImport = false
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
                if let url = BrowserArcAutofillDiscovery.defaultUserDataURL(),
                   let records = try? BrowserAutofillImportReader.readProfiles(from: url) {
                    discoveredArcRecords = records
                } else {
                    discoveredArcRecords = []
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
                onImport: { spaceID, identities in
                    guard let destinationSpace = model.browser.spaceModel(spaceID) else {
                        throw BrowserAutofillStore.AutofillImportAuthorizationError.spaceNotFound
                    }
                    let isLocked = model.spaceAccess.isLocked(destinationSpace)
                    let isPrivate = model.browser.isPrivateBrowsing
                    try autofillStore.importIdentities(
                        identities,
                        into: spaceID,
                        isLocked: isLocked,
                        isPrivate: isPrivate
                    )
                }
            )
        }
#endif
    }
}
