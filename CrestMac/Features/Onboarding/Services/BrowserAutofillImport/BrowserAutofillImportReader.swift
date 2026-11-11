import Foundation
import SQLite3

public struct ArcAutofillProfileRecord: Equatable, Sendable {
    public let guid: String
    public let profileName: String
    public let fullName: String
    public let companyName: String
    public let streetAddress: String
    public let addressLine2: String
    public let city: String
    public let state: String
    public let zipcode: String
    public let countryCode: String
    public let email: String
    public let phoneNumber: String

    public var compoundID: String {
        "\(profileName):\(guid)"
    }

    public init(
        guid: String,
        profileName: String = "Default",
        fullName: String = "",
        companyName: String = "",
        streetAddress: String = "",
        addressLine2: String = "",
        city: String = "",
        state: String = "",
        zipcode: String = "",
        countryCode: String = "",
        email: String = "",
        phoneNumber: String = ""
    ) {
        self.guid = guid
        self.profileName = profileName
        self.fullName = fullName
        self.companyName = companyName
        self.streetAddress = streetAddress
        self.addressLine2 = addressLine2
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
/// Opens read-only with safety PRAGMAs and discovers multiple schema generations:
/// - Modern Chromium `addresses` + `address_type_tokens` (and `local_addresses` + `local_addresses_type_tokens`)
/// - Intermediate `contact_info` + `contact_info_type_tokens`
/// - Classic `autofill_profiles` + auxiliary tables
/// - Legacy single-table `autofill_profiles`
public final class BrowserAutofillImportReader {
    public static let maximumDatabaseByteCount = 512 * 1_024 * 1_024

    // Primary-source Chromium Autofill type IDs (from components/autofill/core/browser/field_types.h):
    // 3: NAME_FIRST
    // 4: NAME_MIDDLE
    // 5: NAME_LAST
    // 7: NAME_FULL
    // 9: EMAIL_ADDRESS
    // 14: PHONE_HOME_WHOLE_NUMBER
    // 30: ADDRESS_HOME_LINE1
    // 31: ADDRESS_HOME_LINE2
    // 33: ADDRESS_HOME_CITY
    // 34: ADDRESS_HOME_STATE
    // 35: ADDRESS_HOME_ZIP
    // 36: ADDRESS_HOME_COUNTRY
    // 60: COMPANY_NAME
    // 77: ADDRESS_HOME_STREET_ADDRESS
    private enum ChromiumFieldType: Int32 {
        case nameFirst = 3
        case nameMiddle = 4
        case nameLast = 5
        case nameFull = 7
        case emailAddress = 9
        case phoneHomeWholeNumber = 14
        case addressHomeLine1 = 30
        case addressHomeLine2 = 31
        case addressHomeCity = 33
        case addressHomeState = 34
        case addressHomeZip = 35
        case addressHomeCountry = 36
        case companyName = 60
        case addressHomeStreetAddress = 77
    }

    private static func tableExists(_ tableName: String, in database: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

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

        // Check which schema tables actually exist in sqlite_master
        if tableExists("addresses", in: database) && tableExists("address_type_tokens", in: database) {
            return try readAddressTokenTable(mainTable: "addresses", tokenTable: "address_type_tokens", from: database)
        }

        if tableExists("local_addresses", in: database) && tableExists("local_addresses_type_tokens", in: database) {
            return try readAddressTokenTable(mainTable: "local_addresses", tokenTable: "local_addresses_type_tokens", from: database)
        }

        if tableExists("contact_info", in: database) && tableExists("contact_info_type_tokens", in: database) {
            return try readAddressTokenTable(mainTable: "contact_info", tokenTable: "contact_info_type_tokens", from: database)
        }

        if tableExists("autofill_profiles", in: database) {
            if tableExists("autofill_profile_names", in: database) {
                return try readStandardProfiles(from: database)
            } else {
                return try readLegacyProfiles(from: database)
            }
        }

        throw BrowserAutofillImportError.unreadableDatabase
    }

    private static func readAddressTokenTable(
        mainTable: String,
        tokenTable: String,
        from database: OpaquePointer
    ) throws -> [ArcAutofillProfileRecord] {
        let sql = "SELECT a.guid, t.type, t.value FROM \(mainTable) a JOIN \(tokenTable) t ON a.guid = t.guid"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BrowserAutofillImportError.unreadableDatabase
        }
        defer { sqlite3_finalize(statement) }

        var dict: [String: [Int32: String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = string(statement, column: 0) else { continue }
            let type = sqlite3_column_int(statement, 1)
            let value = string(statement, column: 2) ?? ""
            if dict[guid] == nil { dict[guid] = [:] }
            dict[guid]?[type] = value
        }

        return dict.map { guid, fields in
            // Authoritative Chromium Autofill mapping:
            let fullName: String
            if let explicitFull = fields[ChromiumFieldType.nameFull.rawValue], !explicitFull.isEmpty {
                fullName = explicitFull
            } else {
                let first = fields[ChromiumFieldType.nameFirst.rawValue] ?? ""
                let last = fields[ChromiumFieldType.nameLast.rawValue] ?? ""
                fullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            }

            let line1 = fields[ChromiumFieldType.addressHomeLine1.rawValue] ?? fields[ChromiumFieldType.addressHomeStreetAddress.rawValue] ?? ""
            let line2 = fields[ChromiumFieldType.addressHomeLine2.rawValue] ?? ""

            return ArcAutofillProfileRecord(
                guid: guid,
                fullName: fullName,
                companyName: fields[ChromiumFieldType.companyName.rawValue] ?? "",
                streetAddress: line1,
                addressLine2: line2,
                city: fields[ChromiumFieldType.addressHomeCity.rawValue] ?? "",
                state: fields[ChromiumFieldType.addressHomeState.rawValue] ?? "",
                zipcode: fields[ChromiumFieldType.addressHomeZip.rawValue] ?? "",
                countryCode: fields[ChromiumFieldType.addressHomeCountry.rawValue] ?? "",
                email: fields[ChromiumFieldType.emailAddress.rawValue] ?? "",
                phoneNumber: fields[ChromiumFieldType.phoneHomeWholeNumber.rawValue] ?? ""
            )
        }
    }

    private static func readStandardProfiles(from database: OpaquePointer) throws -> [ArcAutofillProfileRecord] {
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
            return []
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

extension BrowserAutofillImportReader {
    /// Discovers all available Web Data database profiles within an Arc/Chromium User Data directory.
    public static func discoverProfileDatabases(in userDataDirectory: URL) -> [(profileName: String, databaseURL: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: userDataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var results: [(String, URL)] = []
        for case let url as URL in enumerator {
            let webDataURL = url.appendingPathComponent("Web Data")
            if FileManager.default.fileExists(atPath: webDataURL.path) {
                results.append((url.lastPathComponent, webDataURL))
            }
        }
        return results
    }
}
