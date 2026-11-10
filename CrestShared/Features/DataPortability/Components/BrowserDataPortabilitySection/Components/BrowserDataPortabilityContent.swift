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
                    // Revalidate destination authority at commit time
                    guard let destinationSpace = model.browser.spaceModel(spaceID),
                          !model.spaceAccess.isLocked(destinationSpace),
                          !model.browser.isPrivateBrowsing
                    else {
                        return
                    }
                    autofillStore.importIdentities(identities, into: spaceID)
                }
            )
        }
#endif
    }
}
