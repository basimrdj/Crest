import Foundation
import SQLite3

public struct ArcAutofillProfileRecord: Equatable, Sendable {
    public let guid: String
    public let fullName: String
    public let companyName: String
    public let streetAddress: String
    public let city: String
    public let state: String
    public let zipcode: String
    public let countryCode: String
    public let email: String
    public let phoneNumber: String

    public init(
        guid: String,
        fullName: String = "",
        companyName: String = "",
        streetAddress: String = "",
        city: String = "",
        state: String = "",
        zipcode: String = "",
        countryCode: String = "",
        email: String = "",
        phoneNumber: String = ""
    ) {
        self.guid = guid
        self.fullName = fullName
        self.companyName = companyName
        self.streetAddress = streetAddress
        self.city = city
        self.state = state
        self.zipcode = zipcode
        self.countryCode = countryCode
        self.email = email
        self.phoneNumber = phoneNumber
    }
}

public enum BrowserAutofillImportError: Error, Equatable {
    case unreadableDatabase
    case fileNotFound
}

/// Reads structured autofill addresses and identities from Chromium and Arc Browser `Web Data` SQLite files.
/// Opens read-only with safety PRAGMAs and without touching user passwords or payment records.
public final class BrowserAutofillImportReader {
    public static let maximumDatabaseByteCount = 512 * 1_024 * 1_024

    public static func readProfiles(from databaseURL: URL) throws -> [ArcAutofillProfileRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BrowserAutofillImportError.fileNotFound
        }

        let values = try? databaseURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
            values?.fileSize ?? 0 <= maximumDatabaseByteCount
        else {
            throw BrowserAutofillImportError.unreadableDatabase
        }

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw BrowserAutofillImportError.unreadableDatabase
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 1_000)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA trusted_schema = OFF", nil, nil, nil)

        let sql = """
            SELECT p.guid,
                   COALESCE(n.full_name, ''),
                   COALESCE(p.company_name, ''),
                   COALESCE(p.street_address, ''),
                   COALESCE(p.city, ''),
                   COALESCE(p.state, ''),
                   COALESCE(p.zipcode, ''),
                   COALESCE(p.country_code, ''),
                   COALESCE(e.email, ''),
                   COALESCE(ph.number, '')
            FROM autofill_profiles p
            LEFT JOIN autofill_profile_names n ON p.guid = n.guid
            LEFT JOIN autofill_profile_emails e ON p.guid = e.guid
            LEFT JOIN autofill_profile_phones ph ON p.guid = ph.guid
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            return try readLegacyProfiles(from: database)
        }
        defer { sqlite3_finalize(statement) }

        var records: [ArcAutofillProfileRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = string(statement, column: 0) else { continue }
            let fullName = string(statement, column: 1) ?? ""
            let companyName = string(statement, column: 2) ?? ""
            let streetAddress = string(statement, column: 3) ?? ""
            let city = string(statement, column: 4) ?? ""
            let state = string(statement, column: 5) ?? ""
            let zipcode = string(statement, column: 6) ?? ""
            let countryCode = string(statement, column: 7) ?? ""
            let email = string(statement, column: 8) ?? ""
            let phoneNumber = string(statement, column: 9) ?? ""

            records.append(
                ArcAutofillProfileRecord(
                    guid: guid,
                    fullName: fullName,
                    companyName: companyName,
                    streetAddress: streetAddress,
                    city: city,
                    state: state,
                    zipcode: zipcode,
                    countryCode: countryCode,
                    email: email,
                    phoneNumber: phoneNumber
                )
            )
        }
        return records
    }

    private static func readLegacyProfiles(from database: OpaquePointer) throws -> [ArcAutofillProfileRecord] {
        let legacySql = "SELECT guid, company_name, street_address, city, state, zipcode, country_code FROM autofill_profiles"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, legacySql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw BrowserAutofillImportError.unreadableDatabase
        }
        defer { sqlite3_finalize(statement) }

        var records: [ArcAutofillProfileRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = string(statement, column: 0) else { continue }
            let companyName = string(statement, column: 1) ?? ""
            let streetAddress = string(statement, column: 2) ?? ""
            let city = string(statement, column: 3) ?? ""
            let state = string(statement, column: 4) ?? ""
            let zipcode = string(statement, column: 5) ?? ""
            let countryCode = string(statement, column: 6) ?? ""

            records.append(
                ArcAutofillProfileRecord(
                    guid: guid,
                    companyName: companyName,
                    streetAddress: streetAddress,
                    city: city,
                    state: state,
                    zipcode: zipcode,
                    countryCode: countryCode
                )
            )
        }
        return records
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= 1_048_576 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}
