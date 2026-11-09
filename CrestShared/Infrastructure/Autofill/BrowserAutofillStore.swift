import Foundation
import Observation

/// Space-scoped persistent store for native autofill identities.
/// Preserves Space privacy boundaries and supports CRUD operations.
@Observable
@MainActor
public final class BrowserAutofillStore {
    // MARK: - Variables

    private let userDefaultsKey = "CrestAutofillIdentities"
    public private(set) var identities: [AutofillIdentity] = []

    // MARK: - Initializers

    public init() {
        load()
    }

    // MARK: - Actions - Query

    /// Returns all identities assigned to `spaceID`.
    public func identities(in spaceID: UUID) -> [AutofillIdentity] {
        identities.filter { $0.spaceID == spaceID }
    }

    /// Returns the default identity for `spaceID`, or the first available one if none is marked default.
    public func defaultIdentity(in spaceID: UUID) -> AutofillIdentity? {
        let spaceIdentities = identities(in: spaceID)
        return spaceIdentities.first(where: \.isDefault) ?? spaceIdentities.first
    }

    /// Search identities within a Space matching a text query.
    public func identities(in spaceID: UUID, matching query: String) -> [AutofillIdentity] {
        let spaceIdentities = identities(in: spaceID)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return spaceIdentities }

        return spaceIdentities.filter { identity in
            identity.label.localizedCaseInsensitiveContains(trimmed)
                || identity.fullName.localizedCaseInsensitiveContains(trimmed)
                || identity.givenName.localizedCaseInsensitiveContains(trimmed)
                || identity.familyName.localizedCaseInsensitiveContains(trimmed)
                || identity.email.localizedCaseInsensitiveContains(trimmed)
                || identity.streetAddress.localizedCaseInsensitiveContains(trimmed)
                || identity.city.localizedCaseInsensitiveContains(trimmed)
                || identity.postalCode.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - Actions - Mutations

    /// Saves or updates an identity. If marked as default, unmarks other defaults in the same Space.
    public func save(_ identity: AutofillIdentity) {
        var updated = identity
        updated.updatedAt = Date()

        if updated.isDefault {
            for index in identities.indices where identities[index].spaceID == updated.spaceID {
                identities[index].isDefault = false
            }
        }

        if let existingIndex = identities.firstIndex(where: { $0.id == updated.id }) {
            identities[existingIndex] = updated
        } else {
            // If it's the first identity in this space, make it default automatically
            if !identities.contains(where: { $0.spaceID == updated.spaceID }) {
                updated.isDefault = true
            }
            identities.append(updated)
        }
        persist()
    }

    /// Deletes an identity by its ID.
    public func delete(_ identityID: UUID) {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let removed = identities.remove(at: index)

        // If we deleted the default, assign a new default if any remain in the Space
        if removed.isDefault, let nextIndex = identities.firstIndex(where: { $0.spaceID == removed.spaceID }) {
            identities[nextIndex].isDefault = true
        }
        persist()
    }

    /// Purges all identities associated with a deleted Space.
    public func deleteIdentities(for spaceID: UUID) {
        identities.removeAll(where: { $0.spaceID == spaceID })
        persist()
    }

    /// Imports identities into a destination Space, performing deduplication against existing records.
    @discardableResult
    public func importIdentities(
        _ incoming: [AutofillIdentity],
        into destinationSpaceID: UUID
    ) -> (importedCount: Int, duplicateCount: Int) {
        var imported = 0
        var duplicates = 0
        let existing = identities(in: destinationSpaceID)

        for var item in incoming {
            item.spaceID = destinationSpaceID
            // Deduplication rule: match on normalized email and streetAddress
            let isDuplicate = existing.contains { candidate in
                let emailMatch = !item.email.isEmpty && candidate.email.caseInsensitiveCompare(item.email) == .orderedSame
                let addressMatch = !item.streetAddress.isEmpty && candidate.streetAddress.caseInsensitiveCompare(item.streetAddress) == .orderedSame
                let nameMatch = !item.fullName.isEmpty && candidate.fullName.caseInsensitiveCompare(item.fullName) == .orderedSame
                return (emailMatch && nameMatch) || (addressMatch && nameMatch)
            }

            if isDuplicate {
                duplicates += 1
            } else {
                save(item)
                imported += 1
            }
        }
        return (imported, duplicates)
    }

    // MARK: - Actions - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode([AutofillIdentity].self, from: data)
        else {
            identities = []
            return
        }
        identities = decoded
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(identities) else { return }
        UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
    }
}
