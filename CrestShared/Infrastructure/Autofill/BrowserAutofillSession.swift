import Foundation
import Observation

/// Coordinates in-page autofill suggestions and actions for a tab/page session.
@Observable
@MainActor
public final class BrowserAutofillSession {
    // MARK: - Types

    public struct FocusedFieldInfo: Equatable, Sendable {
        public let formID: String
        public let fieldType: String
        public let rect: CGRect?
        public let frameSecurityOrigin: String?
        public let isMainFrame: Bool
        public let navigationGeneration: UInt64

        public init(
            formID: String,
            fieldType: String,
            rect: CGRect? = nil,
            frameSecurityOrigin: String? = nil,
            isMainFrame: Bool = true,
            navigationGeneration: UInt64 = 0
        ) {
            self.formID = formID
            self.fieldType = fieldType
            self.rect = rect
            self.frameSecurityOrigin = frameSecurityOrigin
            self.isMainFrame = isMainFrame
            self.navigationGeneration = navigationGeneration
        }
    }

    public typealias Evaluate = @MainActor (String, [String: Any]) async throws -> Any?

    // MARK: - Variables

    public let spaceID: UUID
    public let store: BrowserAutofillStore
    public private(set) var activeField: FocusedFieldInfo?
    public var isSuggestionPresented: Bool {
        activeField != nil && !matchingIdentities.isEmpty
    }

    // MARK: - Initializers

    public init(spaceID: UUID, store: BrowserAutofillStore) {
        self.spaceID = spaceID
        self.store = store
    }

    // MARK: - Actions

    public var matchingIdentities: [AutofillIdentity] {
        store.identities(in: spaceID)
    }

    public func receiveMessage(
        _ body: [String: Any],
        frameSecurityOrigin: String? = nil,
        isMainFrame: Bool = true,
        navigationGeneration: UInt64 = 0
    ) {
        guard let event = body["event"] as? String else { return }

        switch event {
        case "focus":
            guard let formID = body["formID"] as? String,
                let fieldType = body["fieldType"] as? String
            else { return }

            var fieldRect: CGRect? = nil
            if let rectDict = body["fieldRect"] as? [String: Double],
                let x = rectDict["x"], let y = rectDict["y"],
                let w = rectDict["width"], let h = rectDict["height"]
            {
                fieldRect = CGRect(x: x, y: y, width: w, height: h)
            }

            activeField = FocusedFieldInfo(
                formID: formID,
                fieldType: fieldType,
                rect: fieldRect,
                frameSecurityOrigin: frameSecurityOrigin,
                isMainFrame: isMainFrame,
                navigationGeneration: navigationGeneration
            )

        case "blur":
            activeField = nil

        default:
            break
        }
    }

    public func fill(
        _ identity: AutofillIdentity,
        expectedNavigationGeneration: UInt64? = nil,
        expectedOrigin: String? = nil,
        evaluate: Evaluate
    ) async throws {
        guard let field = activeField else { return }

        // Validate generation staleness if navigation occurred
        if let expectedGen = expectedNavigationGeneration, field.navigationGeneration != expectedGen {
            activeField = nil
            return
        }

        // Validate security origin matches bound target
        if let expectedOrig = expectedOrigin, let fieldOrig = field.frameSecurityOrigin, !fieldOrig.isEmpty {
            guard fieldOrig == expectedOrig else {
                activeField = nil
                return
            }
        }

        let payload: [String: String] = [
            "fullName": identity.resolvedFullName,
            "givenName": identity.givenName,
            "middleName": identity.middleName,
            "familyName": identity.familyName,
            "organization": identity.organization,
            "email": identity.email,
            "phoneNumber": identity.phoneNumber,
            "streetAddress": identity.streetAddress,
            "addressLine2": identity.addressLine2,
            "city": identity.city,
            "stateOrProvince": identity.stateOrProvince,
            "postalCode": identity.postalCode,
            "countryOrRegion": identity.countryOrRegion,
        ]

        let script = "return globalThis.__crestAutofillBridge?.fill(formID, values) === true;"
        _ = try await evaluate(script, [
            "formID": field.formID,
            "values": payload,
        ])
        activeField = nil
    }

    public func dismiss() {
        activeField = nil
    }
}
