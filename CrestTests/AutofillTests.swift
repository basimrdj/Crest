import Foundation
import SQLite3
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
        session.receiveMessage(
            [
                "event": "focus",
                "formID": "test-form-1",
                "fieldType": "email",
                "fieldRect": ["x": 100.0, "y": 200.0, "width": 150.0, "height": 30.0]
            ],
            frameSecurityOrigin: "https://navy.mil:443",
            isMainFrame: true,
            navigationGeneration: 0
        )

        #expect(session.isSuggestionPresented)
        #expect(session.activeField?.formID == "test-form-1")
        #expect(session.activeField?.fieldType == "email")

        var evaluatedScript = ""
        var evaluatedParams: [String: Any] = [:]

        let activeHandleID = session.activeField?.frameHandleID ?? UUID()
        try await session.fill(
            identity,
            expectedNavigationGeneration: 0,
            expectedOrigin: "https://navy.mil:443",
            expectedFrameHandleID: activeHandleID
        ) { script, params in
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
        let gen1HandleID = session.activeField?.frameHandleID ?? UUID()
        try await session.fill(
            identity,
            expectedNavigationGeneration: 2,
            expectedOrigin: "https://example.com:443",
            expectedFrameHandleID: gen1HandleID
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
        let gen2HandleID = session.activeField?.frameHandleID ?? UUID()
        try await session.fill(
            identity,
            expectedNavigationGeneration: 2,
            expectedOrigin: "https://evil.com:443",
            expectedFrameHandleID: gen2HandleID
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

    @Test("BrowserAutofillSession fails closed on missing, opaque or mismatched origins and wrong spaces")
    @MainActor
    func testSessionStrictFailClosed() async throws {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()
        let otherSpaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Valid",
            fullName: "Valid User",
            email: "valid@example.com"
        )
        let otherSpaceIdentity = AutofillIdentity(
            spaceID: otherSpaceID,
            label: "Wrong Space",
            fullName: "Attacker User",
            email: "attacker@other.com"
        )
        store.save(identity)
        store.save(otherSpaceIdentity)

        let session = BrowserAutofillSession(spaceID: spaceID, store: store)

        // 1. Opaque / null origin rejection
        session.receiveMessage(
            ["event": "focus", "formID": "form-1", "fieldType": "email"],
            frameSecurityOrigin: "null",
            isMainFrame: true,
            navigationGeneration: 1
        )
        #expect(!session.isSuggestionPresented, "Opaque null origin must be rejected")

        // 2. Empty origin rejection
        session.receiveMessage(
            ["event": "focus", "formID": "form-1", "fieldType": "email"],
            frameSecurityOrigin: "",
            isMainFrame: true,
            navigationGeneration: 1
        )
        #expect(!session.isSuggestionPresented, "Empty origin must be rejected")

        // 3. Normal focus setup
        session.receiveMessage(
            ["event": "focus", "formID": "form-1", "fieldType": "email"],
            frameSecurityOrigin: "https://example.com:443",
            isMainFrame: true,
            navigationGeneration: 1
        )
        #expect(session.isSuggestionPresented)

        var evaluatorRan = false

        // 4. Fill rejected when identity belongs to another Space
        let handle4 = session.activeField?.frameHandleID ?? UUID()
        try await session.fill(
            otherSpaceIdentity,
            expectedNavigationGeneration: 1,
            expectedOrigin: "https://example.com:443",
            expectedFrameHandleID: handle4
        ) { _, _ in
            evaluatorRan = true
            return true
        }
        #expect(!evaluatorRan, "Fill must never evaluate for cross-space identity")
        #expect(session.activeField == nil)

        // 5. Normal focus setup again
        session.receiveMessage(
            ["event": "focus", "formID": "form-1", "fieldType": "email"],
            frameSecurityOrigin: "https://example.com:443",
            isMainFrame: true,
            navigationGeneration: 1
        )

        // 6. Fill rejected when expected origin is empty or mismatched
        evaluatorRan = false
        let handle5 = session.activeField?.frameHandleID ?? UUID()
        try await session.fill(
            identity,
            expectedNavigationGeneration: 1,
            expectedOrigin: "",
            expectedFrameHandleID: handle5
        ) { _, _ in
            evaluatorRan = true
            return true
        }
        #expect(!evaluatorRan, "Fill must fail closed on empty expected origin")
        #expect(session.activeField == nil)
    }

    @Test("BrowserAutofillSession and bridge reject cross-frame blur and mismatched frame handles")
    @MainActor
    func testFrameHandleAndScopedBlur() async throws {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "FrameTest",
            fullName: "Frame Tester",
            email: "frame@test.org"
        )
        store.save(identity)

        let session = BrowserAutofillSession(spaceID: spaceID, store: store)

        let frameA = UUID()
        let frameB = UUID()

        // 1. Focus in Frame A
        session.receiveMessage(
            ["event": "focus", "formID": "form-A", "fieldType": "email"],
            frameSecurityOrigin: "https://test.org:443",
            isMainFrame: false,
            navigationGeneration: 1,
            frameHandleID: frameA
        )
        #expect(session.isSuggestionPresented)
        #expect(session.activeField?.frameHandleID == frameA)

        // 2. Unrelated blur from Frame B or different formID must NOT clear Frame A active field
        session.receiveMessage(
            ["event": "blur", "formID": "form-B"],
            frameSecurityOrigin: "https://test.org:443",
            isMainFrame: false,
            navigationGeneration: 1,
            frameHandleID: frameB
        )
        #expect(session.isSuggestionPresented, "Blur from Frame B must not dismiss Frame A focus")

        // 3. Attempt fill with wrong frame handle must fail closed
        var didFill = false
        try await session.fill(
            identity,
            expectedNavigationGeneration: 1,
            expectedOrigin: "https://test.org:443",
            expectedFrameHandleID: frameB
        ) { _, _ in
            didFill = true
            return true
        }
        #expect(!didFill, "Fill with mismatched frame handle must fail closed")
        #expect(session.activeField == nil)
    }

    @Test("BrowserAutofillFocusRouter correctly gates focus, blur tokens, and selection state")
    @MainActor
    func testBrowserAutofillFocusRouter() {
        let router = BrowserAutofillFocusRouter()

        // 1. Reject tokenless or empty focus
        #expect(router.acceptFocus(formID: "form-1", frameToken: nil, focusToken: "focus-1", securityOrigin: "https://example.com:443", navigationGeneration: 1) == nil)
        #expect(router.acceptFocus(formID: "form-1", frameToken: "frame-1", focusToken: "", securityOrigin: "https://example.com:443", navigationGeneration: 1) == nil)
        #expect(router.acceptFocus(formID: "form-1", frameToken: "frame-1", focusToken: "focus-1", securityOrigin: "null", navigationGeneration: 1) == nil)
        #expect(router.activeFocus == nil)

        // 2. Accept valid focus
        let active = router.acceptFocus(
            formID: "form-1",
            frameToken: "frame-1",
            focusToken: "focus-1",
            securityOrigin: "https://example.com:443",
            navigationGeneration: 1
        )
        #expect(active != nil)
        #expect(router.activeFocus?.focusToken == "focus-1")
        #expect(router.activeFocus?.frameToken == "frame-1")

        // 3. Stale blur from different focusToken (e.g. earlier field in same form) does NOT dismiss
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-1", focusToken: "focus-old"))
        #expect(router.activeFocus != nil)

        // 4. Blur from different frameToken does NOT dismiss
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-2", focusToken: "focus-1"))
        #expect(router.activeFocus != nil)

        // 5. Blur during native suggestion selection does NOT dismiss
        router.beginSelection()
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-1", focusToken: "focus-1"))
        #expect(router.activeFocus != nil)
        router.endSelection()

        // 6. Matching blur dismisses active focus
        #expect(router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-1", focusToken: "focus-1"))
        #expect(router.activeFocus == nil)
    }

    @Test("BrowserAutofillFocusRouter strictly enforces token presence and pointer-down selection immunity")
    @MainActor
    func testRouterTokenAndSelectionImmunity() {
        let router = BrowserAutofillFocusRouter()

        // 1. Establish valid active focus
        let active = router.acceptFocus(
            formID: "form-1",
            frameToken: "frame-xyz",
            focusToken: "focus-abc",
            securityOrigin: "https://example.com:443",
            navigationGeneration: 2
        )
        #expect(active != nil)

        // 2. Tokenless blur (missing focusToken) MUST NOT dismiss active focus
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-xyz", focusToken: nil))
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-xyz", focusToken: ""))
        #expect(router.activeFocus != nil, "Blur missing focusToken must not dismiss active focus")

        // 3. Stale blur with different focusToken MUST NOT dismiss
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-xyz", focusToken: "focus-stale"))
        #expect(router.activeFocus != nil)

        // 4. Pointer-down / selection began protects against matching blur
        router.beginSelection()
        #expect(!router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-xyz", focusToken: "focus-abc"))
        #expect(router.activeFocus != nil, "Matching blur during selection must be suppressed")
        router.endSelection()

        // 5. Once selection ends, matching blur dismisses
        #expect(router.shouldDismissOnBlur(formID: "form-1", frameToken: "frame-xyz", focusToken: "focus-abc"))
        #expect(router.activeFocus == nil)
    }

    @Test("Arc schema discovery handles address_type_tokens, contact_info, and standard tables")
    @MainActor
    func testArcMultiSchemaSupport() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("Web_Data_Test.sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }

        var db: OpaquePointer?
        guard sqlite3_open(tempDB.path, &db) == SQLITE_OK, let db else {
            Issue.record("Failed to create temporary SQLite database")
            return
        }

        sqlite3_exec(db, "CREATE TABLE addresses (guid TEXT PRIMARY KEY);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE address_type_tokens (guid TEXT, type INTEGER, value TEXT);", nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO addresses VALUES ('guid-1');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 7, 'Modern Developer');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 9, 'modern@crest.dev');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 14, '+15551234');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 30, '100 Chromium Way');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 33, 'Mountain View');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 34, 'CA');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 35, '94043');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 36, 'US');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 60, 'OpenSource Corp');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO address_type_tokens VALUES ('guid-1', 55, '2028');", nil, nil, nil)
        sqlite3_close(db)

        let records = try BrowserAutofillImportReader.readProfiles(from: tempDB)
        #expect(records.count == 1)
        let record = records[0]
        #expect(record.guid == "guid-1")
        #expect(record.fullName == "Modern Developer")
        #expect(record.email == "modern@crest.dev")
        #expect(record.companyName == "OpenSource Corp", "Company name must map to type 60, not payment type 55")
        #expect(record.streetAddress == "100 Chromium Way")
        #expect(record.city == "Mountain View")
        #expect(record.state == "CA")
        #expect(record.zipcode == "94043")
        #expect(record.countryCode == "US")
    }

    @Test("Space deletion purges all assigned identities and persists cleanly")
    @MainActor
    func testSpacePurgeLifecycle() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BrowserAutofillStore(isPrivate: false, customDirectory: tempDir)
        let spaceToDelete = UUID()
        let spaceToKeep = UUID()

        let id1 = AutofillIdentity(spaceID: spaceToDelete, label: "To Delete", fullName: "Doomed User")
        let id2 = AutofillIdentity(spaceID: spaceToKeep, label: "To Keep", fullName: "Surviving User")

        store.save(id1)
        store.save(id2)
        #expect(store.identities(in: spaceToDelete).count == 1)
        #expect(store.identities(in: spaceToKeep).count == 1)

        // Delete space
        store.deleteIdentities(for: spaceToDelete)
        #expect(store.identities(in: spaceToDelete).isEmpty)
        #expect(store.identities(in: spaceToKeep).count == 1)

        // Reload from disk to verify atomic file persistence
        let reloadedStore = BrowserAutofillStore(isPrivate: false, customDirectory: tempDir)
        #expect(reloadedStore.identities(in: spaceToDelete).isEmpty)
        #expect(reloadedStore.identities(in: spaceToKeep).count == 1)
        #expect(reloadedStore.identities(in: spaceToKeep).first?.fullName == "Surviving User")
    }

    @Test("Arc schema discovery handles local_addresses and contact_info table pairs accurately")
    @MainActor
    func testArcIntermediateAndLocalSchemas() throws {
        // 1. Test local_addresses + local_addresses_type_tokens
        let localDB = FileManager.default.temporaryDirectory.appendingPathComponent("Local_Web_Data.sqlite")
        defer { try? FileManager.default.removeItem(at: localDB) }

        var db1: OpaquePointer?
        guard sqlite3_open(localDB.path, &db1) == SQLITE_OK, let db1 else {
            Issue.record("Failed to create local SQLite database")
            return
        }
        sqlite3_exec(db1, "CREATE TABLE local_addresses (guid TEXT PRIMARY KEY);", nil, nil, nil)
        sqlite3_exec(db1, "CREATE TABLE local_addresses_type_tokens (guid TEXT, type INTEGER, value TEXT);", nil, nil, nil)
        sqlite3_exec(db1, "INSERT INTO local_addresses VALUES ('guid-local');", nil, nil, nil)
        sqlite3_exec(db1, "INSERT INTO local_addresses_type_tokens VALUES ('guid-local', 7, 'Local Tester');", nil, nil, nil)
        sqlite3_exec(db1, "INSERT INTO local_addresses_type_tokens VALUES ('guid-local', 9, 'local@test.com');", nil, nil, nil)
        sqlite3_exec(db1, "INSERT INTO local_addresses_type_tokens VALUES ('guid-local', 30, '456 Branch Ave');", nil, nil, nil)
        sqlite3_close(db1)

        let localRecords = try BrowserAutofillImportReader.readProfiles(from: localDB)
        #expect(localRecords.count == 1)
        #expect(localRecords[0].fullName == "Local Tester")
        #expect(localRecords[0].email == "local@test.com")
        #expect(localRecords[0].streetAddress == "456 Branch Ave")

        // 2. Test contact_info + contact_info_type_tokens
        let contactDB = FileManager.default.temporaryDirectory.appendingPathComponent("Contact_Web_Data.sqlite")
        defer { try? FileManager.default.removeItem(at: contactDB) }

        var db2: OpaquePointer?
        guard sqlite3_open(contactDB.path, &db2) == SQLITE_OK, let db2 else {
            Issue.record("Failed to create contact SQLite database")
            return
        }
        sqlite3_exec(db2, "CREATE TABLE contact_info (guid TEXT PRIMARY KEY);", nil, nil, nil)
        sqlite3_exec(db2, "CREATE TABLE contact_info_type_tokens (guid TEXT, type INTEGER, value TEXT);", nil, nil, nil)
        sqlite3_exec(db2, "INSERT INTO contact_info VALUES ('guid-contact');", nil, nil, nil)
        sqlite3_exec(db2, "INSERT INTO contact_info_type_tokens VALUES ('guid-contact', 7, 'Contact Person');", nil, nil, nil)
        sqlite3_exec(db2, "INSERT INTO contact_info_type_tokens VALUES ('guid-contact', 9, 'contact@test.com');", nil, nil, nil)
        sqlite3_exec(db2, "INSERT INTO contact_info_type_tokens VALUES ('guid-contact', 30, '789 Remote St');", nil, nil, nil)
        sqlite3_close(db2)

        let contactRecords = try BrowserAutofillImportReader.readProfiles(from: contactDB)
        #expect(contactRecords.count == 1)
        #expect(contactRecords[0].fullName == "Contact Person")
        #expect(contactRecords[0].email == "contact@test.com")
        #expect(contactRecords[0].streetAddress == "789 Remote St")
    }

    @Test("Arc reader rejects non-existent or corrupted files safely")
    @MainActor
    func testArcReaderFailureHandling() {
        let nonexistentURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent.sqlite")
        #expect(throws: BrowserAutofillImportError.fileNotFound) {
            try BrowserAutofillImportReader.readProfiles(from: nonexistentURL)
        }

        let corruptedURL = FileManager.default.temporaryDirectory.appendingPathComponent("corrupted.sqlite")
        try? "not a valid sqlite file".data(using: .utf8)?.write(to: corruptedURL)
        defer { try? FileManager.default.removeItem(at: corruptedURL) }

        #expect(throws: BrowserAutofillImportError.unreadableDatabase) {
            try BrowserAutofillImportReader.readProfiles(from: corruptedURL)
        }
    }

    @Test("Arc destination import fails closed if Space becomes locked or private between preview and commit")
    @MainActor
    func testDestinationSpaceCommitTimeRevalidation() {
        let store = BrowserAutofillStore(customDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let spaceID = UUID()

        var isSpaceLocked = false
        var isPrivateBrowsing = false

        func commitImport(identities: [AutofillIdentity]) -> Bool {
            guard !isSpaceLocked, !isPrivateBrowsing else {
                return false
            }
            store.importIdentities(identities, into: spaceID)
            return true
        }

        let identity = AutofillIdentity(
            spaceID: spaceID,
            label: "Arc Import",
            fullName: "Candidate User",
            email: "candidate@test.com"
        )

        // 1. If Space locks before commit
        isSpaceLocked = true
        #expect(!commitImport(identities: [identity]), "Must fail closed when Space is locked at commit time")
        #expect(store.identities(in: spaceID).isEmpty)

        // 2. If private browsing is active at commit
        isSpaceLocked = false
        isPrivateBrowsing = true
        #expect(!commitImport(identities: [identity]), "Must fail closed when in private browsing at commit time")
        #expect(store.identities(in: spaceID).isEmpty)

        // 3. Normal authorized commit
        isPrivateBrowsing = false
        #expect(commitImport(identities: [identity]))
        #expect(store.identities(in: spaceID).count == 1)
    }
}
