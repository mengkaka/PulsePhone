public enum TextKeyboardContract {
  public static let maximumRepeatCount: UInt64 = 100

  public static let letterKeys = "abcdefghijklmnopqrstuvwxyz".map(String.init)
  public static let digitKeys = "0123456789".map(String.init)
  public static let editingKeys = [
    "return", "escape", "backspace", "delete-forward", "tab", "space",
  ]
  public static let punctuationKeys = [
    "minus", "equal", "left-bracket", "right-bracket", "backslash",
    "semicolon", "quote", "grave", "comma", "period", "slash",
  ]
  public static let navigationKeys = [
    "home", "end", "page-up", "page-down", "left", "right", "up", "down",
  ]
  public static let otherKeys = ["caps-lock"]

  public static let keys: Set<String> = Set(
    letterKeys + digitKeys + editingKeys + punctuationKeys + navigationKeys
      + otherKeys
  )

  public static let moves: Set<String> = [
    "left", "right", "up", "down", "word-left", "word-right", "line-start",
    "line-end", "document-start", "document-end",
  ]

  public static let modifierArgumentKeys = [
    "command", "control", "option", "shift",
  ]

  public static func canonicalBoolean(_ value: String) -> Bool? {
    switch value {
    case "true": true
    case "false": false
    default: nil
    }
  }
}
