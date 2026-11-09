import Foundation

/// Discovers Arc Browser's autofill SQLite database location in a macOS user environment.
public enum BrowserArcAutofillDiscovery {
    public static func defaultUserDataURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let arcUserData = home.appendingPathComponent("Library/Application Support/Arc/User Data/Default/Web Data")
        if FileManager.default.fileExists(atPath: arcUserData.path) {
            return arcUserData
        }
        return nil
    }
}
