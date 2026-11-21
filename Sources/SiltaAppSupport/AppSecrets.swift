import SiltaCore

/// Core's secret detection for text the app keeps, such as unsent drafts.
public enum AppSecrets {
  /// Whether the text contains a credential Core would refuse or mask.
  public static func contains(_ text: String) -> Bool {
    !SecretGuard.matches(in: text).isEmpty
  }
}
