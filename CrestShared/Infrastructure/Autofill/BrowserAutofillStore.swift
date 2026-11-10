import Foundation
import Observation

/// Space-scoped persistent store for native autofill identities.
/// Preserves Space privacy boundaries, isolates files per Space in Application Support,
/// and enforces in-memory-only storage for Private Spaces.
@Observable
@MainActor
public final class BrowserAutofillStore {
    // MARK: - Variables

    public static let shared = BrowserAutofillStore()

    public let isPrivate: Bool
    public private(set) var identities: [AutofillIdentity] = []
    private let storageDirectory: URL?

    // MARK: - Initializers

    public init(isPrivate: Bool = false, customDirectory: URL? = nil) {
        self.isPrivate = isPrivate
        if isPrivate {
            storageDirectory = nil
        } else if let customDirectory {
            storageDirectory = customDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            storageDirectory = appSupport?.appendingPathComponent("Crest/Autofill", isDirectory: true)
        }
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
            identities.append(updated)
        }
        persist()
    }

    /// Removes an identity from the store.
    public func delete(id: UUID) {
        identities.removeAll { $0.id == id }
        persist()
    }

    /// Deletes all identities associated with a specific Space (e.g. on Space deletion).
    public func deleteIdentities(for spaceID: UUID) {
        identities.removeAll { $0.spaceID == spaceID }
        persist()
    }

    /// Batch imports identities into a destination Space, deduplicating against existing entries.
    @discardableResult
    public func importIdentities(
        _ incoming: [AutofillIdentity],
        into destinationSpaceID: UUID
    ) -> (importedCount: Int, duplicateCount: Int) {
        let current = identities(in: destinationSpaceID)
        var duplicates = 0
        var imported = 0

        for candidate in incoming {
            var item = candidate
            item.spaceID = destinationSpaceID

            let isDuplicate = current.contains { existing in
                let emailMatch = !item.email.isEmpty && existing.email.caseInsensitiveCompare(item.email) == .orderedSame
                let addressMatch = !item.streetAddress.isEmpty && existing.streetAddress.caseInsensitiveCompare(item.streetAddress) == .orderedSame
                let nameMatch = !item.fullName.isEmpty && existing.fullName.caseInsensitiveCompare(item.fullName) == .orderedSame
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

    private var storageFileURL: URL? {
        storageDirectory?.appendingPathComponent("identities.json")
    }

    private func load() {
        guard !isPrivate, let fileURL = storageFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            identities = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            identities = try JSONDecoder().decode([AutofillIdentity].self, from: data)
        } catch {
            identities = []
        }
    }

    private func persist() {
        guard !isPrivate, let directory = storageDirectory, let fileURL = storageFileURL else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(identities)
            try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Log or retain in memory if disk write fails
        }
    }
}
