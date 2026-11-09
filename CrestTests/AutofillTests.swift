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
        let store = BrowserAutofillStore()
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
        let store = BrowserAutofillStore()
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
        let store = BrowserAutofillStore()
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
}
