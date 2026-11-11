import Foundation

// MARK: - Types

/// Represents a reusable personal identity or address record for native form autofill.
/// Scoped to a Space to preserve privacy boundaries.
public struct AutofillIdentity: Identifiable, Hashable, Codable, Sendable {
    // MARK: - Variables

    public var id: UUID
    public var spaceID: UUID
    public var label: String // e.g., "Personal", "Work", "Home"
    public var isDefault: Bool

    // Structured Name
    public var fullName: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var organization: String

    // Contact
    public var email: String
    public var phoneNumber: String

    // Structured Address
    public var streetAddress: String
    public var addressLine2: String
    public var city: String
    public var stateOrProvince: String
    public var postalCode: String
    public var countryOrRegion: String

    public var updatedAt: Date

    // MARK: - Initializers

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        label: String = "Personal",
        isDefault: Bool = false,
        fullName: String = "",
        givenName: String = "",
        middleName: String = "",
        familyName: String = "",
        organization: String = "",
        email: String = "",
        phoneNumber: String = "",
        streetAddress: String = "",
        addressLine2: String = "",
        city: String = "",
        stateOrProvince: String = "",
        postalCode: String = "",
        countryOrRegion: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.label = label
        self.isDefault = isDefault
        self.fullName = fullName
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.organization = organization
        self.email = email
        self.phoneNumber = phoneNumber
        self.streetAddress = streetAddress
        self.addressLine2 = addressLine2
        self.city = city
        self.stateOrProvince = stateOrProvince
        self.postalCode = postalCode
        self.countryOrRegion = countryOrRegion
        self.updatedAt = updatedAt
    }

    // MARK: - Actions

    /// Resolved display name for the identity, falling back to full name, given name, email, or label.
    public var displayName: String {
        let trimmedFull = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFull.isEmpty { return trimmedFull }

        let combined = [givenName, middleName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !combined.isEmpty { return combined }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty { return trimmedEmail }

        return label.isEmpty ? "Identity" : label
    }

    /// Single line summary of the address for selection or preview.
    public var addressSummary: String {
        let parts = [streetAddress, addressLine2, city, stateOrProvince, postalCode, countryOrRegion]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "No address saved" : parts.joined(separator: ", ")
    }

    /// Formats the full name if blank but components exist.
    public var resolvedFullName: String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return [givenName, middleName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
