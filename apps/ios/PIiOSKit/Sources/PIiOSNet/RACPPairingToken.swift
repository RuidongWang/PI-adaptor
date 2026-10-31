import Foundation

/// Validation for the short-lived token printed by `pi-host --pair`.
public enum RACPPairingToken {
    public static func normalize(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > "ppt1.".count,
              token.hasPrefix("ppt1.") || token.hasPrefix("ppt2."),
              !token.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        return token
    }
}
