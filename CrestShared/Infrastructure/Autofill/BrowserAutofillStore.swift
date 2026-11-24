import Foundation
import Observation

public enum BrowserAutofillPersistenceError: Error, Equatable {
    case writeFailed(spaceID: UUID)
    case loadFailed
}

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
    public private(set) var loadFailureMessage: String?
    public private(set) var writeFailureMessage: String?
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
    /// If it is the first identity in the Space, automatically marks it as default.
    /// Throws and rolls back the in-memory change when the durable write fails.
    public func save(_ identity: AutofillIdentity) throws {
        var updated = identity
        updated.updatedAt = Date()

        try mutate(spaceID: updated.spaceID) {
            let existingInSpace = identities.filter { $0.spaceID == updated.spaceID && $0.id != updated.id }
            if existingInSpace.isEmpty {
                updated.isDefault = true
            } else if updated.isDefault {
                for index in identities.indices where identities[index].spaceID == updated.spaceID {
                    identities[index].isDefault = false
                }
            }

            if let existingIndex = identities.firstIndex(where: { $0.id == updated.id }) {
                identities[existingIndex] = updated
            } else {
                identities.append(updated)
            }
        }
    }

    /// Removes an identity from the store.
    /// Throws and rolls back the in-memory change when the durable write fails.
    public func delete(_ identityID: UUID) throws {
        let deletedSpaceID = identities.first(where: { $0.id == identityID })?.spaceID
        try mutate(spaceID: deletedSpaceID) {
            identities.removeAll { $0.id == identityID }
            // If a default identity was deleted, promote another identity in that Space if available
            if let spaceID = deletedSpaceID, !identities.contains(where: { $0.spaceID == spaceID && $0.isDefault }) {
                if let firstIndex = identities.firstIndex(where: { $0.spaceID == spaceID }) {
                    identities[firstIndex].isDefault = true
                }
            }
        }
    }

    public func delete(id: UUID) throws {
        try delete(id)
    }

    /// Deletes all identities associated with a specific Space (e.g. on Space deletion).
    /// Throws and rolls back the in-memory change when the durable write fails.
    public func deleteIdentities(for spaceID: UUID) throws {
        try mutate(spaceID: spaceID) {
            identities.removeAll { $0.spaceID == spaceID }
        }
    }

    public enum AutofillImportAuthorizationError: Error, Equatable {
        case destinationLocked
        case privateBrowsingActive
        case spaceNotFound
        case unauthorizedDestination
    }

    /// An authoritative capability token certifying that the destination Space exists,
    /// is unlocked, and is non-private.
    public struct DestinationAuthorizationToken: Equatable, Sendable {
        public let spaceID: UUID
        fileprivate let validator: @MainActor () -> Bool

        public static func == (lhs: DestinationAuthorizationToken, rhs: DestinationAuthorizationToken) -> Bool {
            lhs.spaceID == rhs.spaceID
        }

        @MainActor
        internal init(
            spaceID: UUID,
            validator: @escaping @MainActor () -> Bool
        ) {
            self.spaceID = spaceID
            self.validator = validator
        }
    }

    /// Batch imports identities into a destination Space, deduplicating against existing entries,
    /// revalidating Space authorization at the exact moment of store mutation.
    @discardableResult
    public func importIdentities(
        _ incoming: [AutofillIdentity],
        into destinationSpaceID: UUID,
        authorization: DestinationAuthorizationToken
    ) throws -> (importedCount: Int, duplicateCount: Int) {
        guard authorization.spaceID == destinationSpaceID else {
            throw AutofillImportAuthorizationError.unauthorizedDestination
        }
        guard authorization.validator() else {
            throw AutofillImportAuthorizationError.destinationLocked
        }

        var imported = 0
        var duplicates = 0
        try mutate(spaceID: destinationSpaceID) {
            var existingInSpace = self.identities(in: destinationSpaceID)
            let (batchImported, batchDuplicates) = self.stageImport(
                incoming, into: destinationSpaceID, existingInSpace: &existingInSpace)
            imported = batchImported
            duplicates = batchDuplicates
        }

        return (imported, duplicates)
    }

    private func stageImport(
        _ incoming: [AutofillIdentity],
        into destinationSpaceID: UUID,
        existingInSpace: inout [AutofillIdentity]
    ) -> (imported: Int, duplicates: Int) {
        var duplicates = 0
        var imported = 0
        var staged: [AutofillIdentity] = []

        for candidate in incoming {
            var item = candidate
            item.spaceID = destinationSpaceID

            // Check duplicate against existing Space records AND newly staged intra-batch records
            let isDuplicate = existingInSpace.contains { existing in
                let emailMatch =
                    !item.email.isEmpty && existing.email.caseInsensitiveCompare(item.email) == .orderedSame
                let addressMatch =
                    !item.streetAddress.isEmpty
                    && existing.streetAddress.caseInsensitiveCompare(item.streetAddress) == .orderedSame
                let nameMatch =
                    !item.fullName.isEmpty && existing.fullName.caseInsensitiveCompare(item.fullName) == .orderedSame
                return (emailMatch && nameMatch) || (addressMatch && nameMatch)
            }

            if isDuplicate {
                duplicates += 1
            } else {
                item.updatedAt = Date()
                if existingInSpace.isEmpty && staged.isEmpty {
                    item.isDefault = true
                }
                staged.append(item)
                existingInSpace.append(item)
                imported += 1
            }
        }

        identities.append(contentsOf: staged)
        return (imported, duplicates)
    }

    // MARK: - Actions - Persistence

    private var spacesDirectory: URL? {
        storageDirectory?.appendingPathComponent("Spaces", isDirectory: true)
    }

    private var legacyStorageFileURL: URL? {
        storageDirectory?.appendingPathComponent("identities.json")
    }

    private func spaceFileURL(for spaceID: UUID) -> URL? {
        spacesDirectory?.appendingPathComponent(spaceID.uuidString, isDirectory: true)
            .appendingPathComponent("identities.json")
    }

    /// Applies `body` to the in-memory state, durably persists the affected Space, and rolls
    /// the in-memory state back to its snapshot when the write fails.
    private func mutate(spaceID: UUID?, _ body: () -> Void) throws {
        let snapshot = identities
        body()
        guard let spaceID else { return }
        guard !isPrivate else { return }
        do {
            try persist(spaceID: spaceID)
            writeFailureMessage = nil
        } catch {
            identities = snapshot
            writeFailureMessage =
                "Crest couldn't save your autofill identities for this Space. The change was kept in memory but not written to disk."
            throw BrowserAutofillPersistenceError.writeFailed(spaceID: spaceID)
        }
    }

    /// Durably writes one Space's identities to that Space's own file.
    /// A Space with no records has its file removed so deleted data never returns on relaunch.
    private func persist(spaceID: UUID) throws {
        guard let spacesDirectory else { return }
        guard let fileURL = spaceFileURL(for: spaceID) else { return }
        let records = identities.filter { $0.spaceID == spaceID }

        if records.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
            return
        }

        try FileManager.default.createDirectory(at: spacesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(records)
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func load() {
        guard !isPrivate else {
            identities = []
            return
        }

        identityLoadFromPerSpaceFiles()
        migrateLegacyFileIfNeeded()
    }

    private func identityLoadFromPerSpaceFiles() {
        guard let spacesDirectory,
            FileManager.default.fileExists(atPath: spacesDirectory.path)
        else { return }

        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: spacesDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for directory in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where directory.hasDirectoryPath {
            let fileURL = directory.appendingPathComponent("identities.json")
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            do {
                identities.append(contentsOf: try JSONDecoder().decode([AutofillIdentity].self, from: data))
            } catch {
                loadFailureMessage = "Some saved autofill identities could not be read and were skipped."
            }
        }
    }

    /// Moves a pre-per-Space-layout `identities.json` into per-Space files, then removes
    /// the legacy file so stale records cannot reappear after deletion. The legacy file is only
    /// deleted after every Space wrote successfully.
    private func migrateLegacyFileIfNeeded() {
        guard let legacyURL = legacyStorageFileURL,
            FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }

        guard let data = try? Data(contentsOf: legacyURL),
            let legacyIdentities = try? JSONDecoder().decode([AutofillIdentity].self, from: data)
        else {
            loadFailureMessage = "Crest's earlier autofill identities could not be read and were skipped."
            return
        }

        let legacySpaceIDs = Set(legacyIdentities.map(\.spaceID))
        var migrationFailed = false
        for spaceID in legacySpaceIDs {
            let legacyRecords = legacyIdentities.filter { $0.spaceID == spaceID }
            guard let fileURL = spaceFileURL(for: spaceID),
                let spacesDirectory = spacesDirectory
            else { continue }
            do {
                try FileManager.default.createDirectory(at: spacesDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(legacyRecords).write(to: fileURL, options: [.atomic, .completeFileProtection])
            } catch {
                migrationFailed = true
                break
            }
        }

        if migrationFailed {
            loadFailureMessage =
                "Crest could not migrate some saved autofill identities into the new per-Space storage."
            return
        }

        let knownIDs = Set(identities.map(\.id))
        identities.append(contentsOf: legacyIdentities.filter { !knownIDs.contains($0.id) })
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
