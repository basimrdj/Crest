import Foundation

/// Coordinates focus and blur events for autofill across frames and document lifecycles.
@MainActor
public final class BrowserAutofillFocusRouter {
    public struct ActiveFocus: Equatable, Sendable {
        public let formID: String
        public let frameToken: String
        public let focusToken: String
        public let handleID: UUID
        public let navigationGeneration: UInt64
        public let securityOrigin: String

        public init(
            formID: String,
            frameToken: String,
            focusToken: String,
            handleID: UUID = UUID(),
            navigationGeneration: UInt64 = 0,
            securityOrigin: String
        ) {
            self.formID = formID
            self.frameToken = frameToken
            self.focusToken = focusToken
            self.handleID = handleID
            self.navigationGeneration = navigationGeneration
            self.securityOrigin = securityOrigin
        }
    }

    public private(set) var activeFocus: ActiveFocus?
    public private(set) var isSelecting: Bool = false

    public init() {}

    public func beginSelection() {
        isSelecting = true
    }

    public func endSelection() {
        isSelecting = false
    }

    /// Evaluates whether an incoming focus event should be accepted.
    public func acceptFocus(
        formID: String,
        frameToken: String?,
        focusToken: String?,
        securityOrigin: String,
        navigationGeneration: UInt64
    ) -> ActiveFocus? {
        guard let frameToken, !frameToken.isEmpty,
            let focusToken, !focusToken.isEmpty,
            !securityOrigin.isEmpty, securityOrigin != "null"
        else {
            return nil
        }
        let focus = ActiveFocus(
            formID: formID,
            frameToken: frameToken,
            focusToken: focusToken,
            handleID: UUID(),
            navigationGeneration: navigationGeneration,
            securityOrigin: securityOrigin
        )
        self.activeFocus = focus
        self.isSelecting = false
        return focus
    }

    /// Evaluates whether an incoming blur event should dismiss the active focus.
    public func shouldDismissOnBlur(
        formID: String?,
        frameToken: String?,
        focusToken: String?
    ) -> Bool {
        // If a native suggestion selection is in progress, do not dismiss
        guard !isSelecting else { return false }
        guard let current = activeFocus else { return false }

        // Must match frameToken
        guard let frameToken, frameToken == current.frameToken else { return false }

        // If focusToken is provided, it must match the active focus token
        if let focusToken, !focusToken.isEmpty {
            guard focusToken == current.focusToken else { return false }
        }

        // If formID is provided, it must match
        if let formID, !formID.isEmpty {
            guard formID == current.formID else { return false }
        }

        activeFocus = nil
        return true
    }

    public func invalidate() {
        activeFocus = nil
        isSelecting = false
    }
}
