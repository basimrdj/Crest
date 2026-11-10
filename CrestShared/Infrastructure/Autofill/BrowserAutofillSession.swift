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
        public let frameSecurityOrigin: String
        public let isMainFrame: Bool
        public let navigationGeneration: UInt64
        public let frameHandleID: UUID

        public init(
            formID: String,
            fieldType: String,
            rect: CGRect? = nil,
            frameSecurityOrigin: String,
            isMainFrame: Bool = true,
            navigationGeneration: UInt64 = 0,
            frameHandleID: UUID = UUID()
        ) {
            self.formID = formID
            self.fieldType = fieldType
            self.rect = rect
            self.frameSecurityOrigin = frameSecurityOrigin
            self.isMainFrame = isMainFrame
            self.navigationGeneration = navigationGeneration
            self.frameHandleID = frameHandleID
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
        frameSecurityOrigin: String,
        isMainFrame: Bool = true,
        navigationGeneration: UInt64 = 0,
        frameHandleID: UUID = UUID()
    ) {
        guard !frameSecurityOrigin.isEmpty, frameSecurityOrigin != "null" else {
            // Fail closed on opaque, null, or empty security origins
            activeField = nil
            return
        }

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
                navigationGeneration: navigationGeneration,
                frameHandleID: frameHandleID
            )

        case "blur":
            // Only dismiss active field if the blur event matches the focused form and frame
            if let formID = body["formID"] as? String {
                if activeField?.formID == formID && activeField?.frameHandleID == frameHandleID {
                    activeField = nil
                }
            } else if activeField?.frameHandleID == frameHandleID {
                activeField = nil
            }

        default:
            break
        }
    }

    public func fill(
        _ identity: AutofillIdentity,
        expectedNavigationGeneration: UInt64,
        expectedOrigin: String,
        expectedFrameHandleID: UUID,
        evaluate: Evaluate
    ) async throws {
        guard let field = activeField else { return }

        // Strict Space isolation check (fail closed)
        guard identity.spaceID == spaceID else {
            activeField = nil
            return
        }

        // Strict generation staleness check (fail closed)
        guard field.navigationGeneration == expectedNavigationGeneration else {
            activeField = nil
            return
        }

        // Strict security origin validation (fail closed)
        guard !expectedOrigin.isEmpty, field.frameSecurityOrigin == expectedOrigin else {
            activeField = nil
            return
        }

        // Strict frame handle match (fail closed)
        guard field.frameHandleID == expectedFrameHandleID else {
            activeField = nil
            return
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
