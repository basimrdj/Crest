import Foundation
import Testing

@testable import CrestShared
@testable import CrestMac

@Suite("Autofill and Arc Migration Tests")
struct AutofillTests {
    @Test("AutofillIdentity resolves display name and formatted address accurately")
    func testIdentityDisplayAndAddress() {
        let spaceID = UUID()
        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Home",
            fullName: "Ada Lovelace",
            givenName: "Ada",
            familyName: "Lovelace",
            organization: "Analytical Engine Co",
            email: "ada@example.com",
            phoneNumber: "+44 20 7946 0991",
            streetAddress: "12 St James's Square",
            city: "London",
            postalCode: "SW1Y 4LE",
            countryOrRegion: "United Kingdom"
        )

        #expect(identity.displayName == "Ada Lovelace")
        #expect(identity.resolvedFullName == "Ada Lovelace")
        #expect(identity.addressSummary == "12 St James's Square, London, SW1Y 4LE, United Kingdom")
    }

    @Test("BrowserAutofillStore enforces strict Space isolation")
    @MainActor
    func testSpaceIsolation() {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceA = UUID()
        let spaceB = UUID()

        let idA = AutofillIdentity(
            spaceID: spaceA,
            label: "Work",
            fullName: "Alice Developer",
            email: "alice@work.com"
        )
        let idB = AutofillIdentity(
            spaceID: spaceB,
            label: "Personal",
            fullName: "Bob Private",
            email: "bob@personal.com"
        )

        store.save(idA)
        store.save(idB)

        let spaceAIdentities = store.identities(in: spaceA)
        let spaceBIdentities = store.identities(in: spaceB)

        #expect(spaceAIdentities.count == 1)
        #expect(spaceAIdentities.first?.fullName == "Alice Developer")

        #expect(spaceBIdentities.count == 1)
        #expect(spaceBIdentities.first?.fullName == "Bob Private")

        // Clean up
        store.deleteIdentities(for: spaceA)
        store.deleteIdentities(for: spaceB)
        #expect(store.identities(in: spaceA).isEmpty)
        #expect(store.identities(in: spaceB).isEmpty)
    }

    @Test("BrowserAutofillStore handles deduplication during import")
    @MainActor
    func testImportDeduplication() {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let destinationSpace = UUID()

        let existing = AutofillIdentity(
            spaceID: destinationSpace,
            label: "Existing",
            fullName: "Carol Danvers",
            email: "carol@marvel.com",
            streetAddress: "100 Main St"
        )
        store.save(existing)

        let duplicate = AutofillIdentity(
            spaceID: UUID(), // different origin space
            label: "Arc Import",
            fullName: "Carol Danvers",
            email: "carol@marvel.com",
            streetAddress: "100 Main St"
        )

        let novel = AutofillIdentity(
            spaceID: UUID(),
            label: "New Identity",
            fullName: "Bruce Banner",
            email: "bruce@avengers.com",
            streetAddress: "200 Lab Rd"
        )

        let result = store.importIdentities([duplicate, novel], into: destinationSpace)
        #expect(result.duplicateCount == 1)
        #expect(result.importedCount == 1)

        let allInSpace = store.identities(in: destinationSpace)
        #expect(allInSpace.count == 2)

        // Clean up
        store.deleteIdentities(for: destinationSpace)
    }

    @Test("BrowserAutofillSession manages focus and fill lifecycle without submitting")
    @MainActor
    func testSessionFillLifecycle() async throws {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Default",
            fullName: "Grace Hopper",
            email: "grace@navy.mil"
        )
        store.save(identity)

        let session = BrowserAutofillSession(spaceID: spaceID, store: store)

        #expect(!session.isSuggestionPresented)

        // Simulate focus message from in-page content bridge
        session.receiveMessage([
            "event": "focus",
            "formID": "test-form-1",
            "fieldType": "email",
            "fieldRect": ["x": 100.0, "y": 200.0, "width": 150.0, "height": 30.0]
        ])

        #expect(session.isSuggestionPresented)
        #expect(session.activeField?.formID == "test-form-1")
        #expect(session.activeField?.fieldType == "email")

        var evaluatedScript = ""
        var evaluatedParams: [String: Any] = [:]

        try await session.fill(identity) { script, params in
            evaluatedScript = script
            evaluatedParams = params
            return true
        }

        #expect(evaluatedScript.contains("__crestAutofillBridge?.fill"))
        #expect(evaluatedParams["formID"] as? String == "test-form-1")
        if let values = evaluatedParams["values"] as? [String: String] {
            #expect(values["email"] == "grace@navy.mil")
            #expect(values["fullName"] == "Grace Hopper")
        } else {
            Issue.record("Expected payload values dictionary")
        }

        #expect(session.activeField == nil)
        store.deleteIdentities(for: spaceID)
    }

    @Test("BrowserAutofillSuggestionOverlay handles empty identities safely")
    @MainActor
    func testOverlayEmptyIdentities() {
        var dismissed = false
        let overlay = BrowserAutofillSuggestionOverlay(
            fieldRect: .zero,
            identities: [],
            spaceAccent: .blue,
            onSelect: { _ in },
            onDismiss: { dismissed = true }
        )
        #expect(overlay.identities.isEmpty)
        overlay.onDismiss()
        #expect(dismissed)
    }

    @Test("BrowserAutofillStore enforces zero disk footprint in private browsing")
    @MainActor
    func testPrivateStoreZeroDiskFootprint() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let privateStore = BrowserAutofillStore(isPrivate: true, customDirectory: tempDir)
        let spaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Ephemeral",
            fullName: "Private User",
            email: "private@user.com"
        )

        privateStore.save(identity)
        #expect(privateStore.identities(in: spaceID).count == 1)

        // Verify no files written to disk
        let fileURL = tempDir.appendingPathComponent("identities.json")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Concurrent edits across shared store consumers survive reload without loss")
    @MainActor
    func testConcurrentSharedStoreEdits() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeA = BrowserAutofillStore(isPrivate: false, customDirectory: tempDir)
        let space1 = UUID()
        let space2 = UUID()

        let id1 = AutofillIdentity(spaceID: space1, label: "Page1", fullName: "User One")
        let id2 = AutofillIdentity(spaceID: space2, label: "Page2", fullName: "User Two")

        storeA.save(id1)
        storeA.save(id2)

        let storeB = BrowserAutofillStore(isPrivate: false, customDirectory: tempDir)
        #expect(storeB.identities(in: space1).count == 1)
        #expect(storeB.identities(in: space2).count == 1)
    }

    @Test("BrowserAutofillSession rejects focus or fill across navigation generations or mismatched origins")
    @MainActor
    func testSessionOriginAndGenerationBinding() async throws {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Test",
            fullName: "Ada Lovelace",
            email: "ada@example.com"
        )
        store.save(identity)

        let session = BrowserAutofillSession(spaceID: spaceID, store: store)

        // Receive focus for generation 1 and origin A
        session.receiveMessage(
            [
                "event": "focus",
                "formID": "form-1",
                "fieldType": "email"
            ],
            frameSecurityOrigin: "https://example.com:443",
            isMainFrame: true,
            navigationGeneration: 1
        )

        #expect(session.isSuggestionPresented)

        var filled = false
        // Attempt fill with stale generation (e.g. page navigated to generation 2)
        try await session.fill(
            identity,
            expectedNavigationGeneration: 2,
            expectedOrigin: "https://example.com:443"
        ) { _, _ in
            filled = true
            return true
        }

        #expect(!filled, "Fill should be rejected when navigation generation is stale")
        #expect(session.activeField == nil, "Active field must be revoked on stale generation")

        // Receive focus again for generation 2
        session.receiveMessage(
            [
                "event": "focus",
                "formID": "form-1",
                "fieldType": "email"
            ],
            frameSecurityOrigin: "https://example.com:443",
            isMainFrame: true,
            navigationGeneration: 2
        )

        // Attempt fill from different origin (e.g. cross-origin iframe attempt)
        try await session.fill(
            identity,
            expectedNavigationGeneration: 2,
            expectedOrigin: "https://evil.com:443"
        ) { _, _ in
            filled = true
            return true
        }

        #expect(!filled, "Fill should be rejected when origin does not match focused frame")
        #expect(session.activeField == nil, "Active field must be revoked on origin mismatch")
    }

    @Test("Synthetic focus delivered before privacy configuration is safely ignored")
    @MainActor
    func testPrePrivacyPolicyMessageRejection() {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Confidential",
            fullName: "Secret Agent",
            email: "agent@crest.test"
        )
        store.save(identity)

        // Simulate a fresh session where privacy is unresolved
        var sessionCreated = false
        var isPolicyConfigured = false

        func handleIncomingEvent() -> BrowserAutofillSession? {
            guard isPolicyConfigured else { return nil }
            sessionCreated = true
            return BrowserAutofillSession(spaceID: spaceID, store: store)
        }

        // Before configuration is applied
        #expect(handleIncomingEvent() == nil)
        #expect(!sessionCreated)

        // Once configured as private
        isPolicyConfigured = true
        let privateStore = BrowserAutofillStore(isPrivate: true)
        let session = BrowserAutofillSession(spaceID: spaceID, store: privateStore)
        #expect(session.matchingIdentities.isEmpty)
    }
}
