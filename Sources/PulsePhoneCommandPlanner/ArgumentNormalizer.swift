import Foundation

public enum ArgumentNormalizationError: Error, Equatable, Sendable {
  case unexpectedKeys
  case missing(String)
  case invalid(String)
  case tooLarge(String)
}

public struct NormalizedPointV1: Equatable, Sendable {
  public let x: String
  public let y: String

  public init(x: String, y: String) {
    self.x = x
    self.y = y
  }
}

public enum NormalizedArgumentValue: Equatable, Sendable {
  case point(NormalizedPointV1)
  case string(String)
  case uint64(UInt64)
}

public struct NormalizedArgumentsV1: Equatable, Sendable {
  public let values: [String: NormalizedArgumentValue]

  public init(values: [String: NormalizedArgumentValue]) {
    self.values = values
  }

  public func string(_ key: String) -> String? {
    guard case .string(let value)? = values[key] else {
      return nil
    }
    return value
  }
}

public enum ArgumentNormalizer {
  public static func normalize(
    schemaID: String,
    raw: [String: String]
  ) throws -> NormalizedArgumentsV1 {
    switch schemaID {
    case "none.v1":
      try requireKeys(raw, expected: [])
      return NormalizedArgumentsV1(values: [:])
    case "bundleID.v1":
      try requireKeys(raw, expected: ["bundleID"])
      let value = try required(raw, "bundleID")
      guard isValidBundleID(value) else {
        throw ArgumentNormalizationError.invalid("bundleID")
      }
      return NormalizedArgumentsV1(values: ["bundleID": .string(value)])
    case "ipaPath.v1":
      return try normalizedPath(raw, key: "ipaPath", requiredSuffix: ".ipa")
    case "outputPath.v1":
      return try normalizedPath(raw, key: "outputPath", requiredSuffix: nil)
    case "elementSnapshot.v1":
      guard Set(raw.keys).isSubset(of: ["force", "format", "outputPath"]) else {
        throw ArgumentNormalizationError.unexpectedKeys
      }
      let format = raw["format"] ?? "json"
      guard ["annotated", "both", "json"].contains(format) else {
        throw ArgumentNormalizationError.invalid("format")
      }
      let force = try canonicalBoolean(raw.merging(["force": "false"]) { value, _ in value }, key: "force")
      let outputPath = try raw["outputPath"].map {
        try normalizedPathValue($0, key: "outputPath", requiredSuffix: nil)
      }
      switch format {
      case "json":
        guard outputPath == nil, !force else {
          throw ArgumentNormalizationError.invalid("format")
        }
      case "annotated", "both":
        guard outputPath != nil else {
          throw ArgumentNormalizationError.missing("outputPath")
        }
      default:
        throw ArgumentNormalizationError.invalid("format")
      }
      var values: [String: NormalizedArgumentValue] = [
        "force": .string(String(force)),
        "format": .string(format),
      ]
      if let outputPath {
        values["outputPath"] = .string(outputPath)
      }
      return NormalizedArgumentsV1(values: values)
    case "normalizedPoint.v1":
      try requireKeys(raw, expected: ["point"])
      return NormalizedArgumentsV1(
        values: ["point": .point(try parsePoint(required(raw, "point"), key: "point"))]
      )
    case "linearGesture.v1":
      try requireKeys(raw, expected: ["durationMs", "from", "to"])
      guard let duration = UInt64(try required(raw, "durationMs")),
        (1...30_000).contains(duration)
      else {
        throw ArgumentNormalizationError.invalid("durationMs")
      }
      return NormalizedArgumentsV1(values: [
        "durationMs": .uint64(duration),
        "from": .point(try parsePoint(required(raw, "from"), key: "from")),
        "to": .point(try parsePoint(required(raw, "to"), key: "to")),
      ])
    case "rotateDirection.v1":
      try requireKeys(raw, expected: ["direction"])
      let direction = try required(raw, "direction")
      guard ["landscapeLeft", "landscapeRight", "portrait"].contains(direction) else {
        throw ArgumentNormalizationError.invalid("direction")
      }
      return NormalizedArgumentsV1(values: ["direction": .string(direction)])
    case "rotateDirection.v2":
      try requireKeys(raw, expected: ["direction"])
      let direction = try required(raw, "direction")
      guard ["left", "right"].contains(direction) else {
        throw ArgumentNormalizationError.invalid("direction")
      }
      return NormalizedArgumentsV1(values: ["direction": .string(direction)])
    case "textCursor.v1":
      try requireKeys(raw, expected: ["count", "move", "select"])
      let move = try required(raw, "move")
      guard TextKeyboardContract.moves.contains(move) else {
        throw ArgumentNormalizationError.invalid("move")
      }
      let count = try boundedKeyboardCount(raw, key: "count")
      let select = try canonicalBoolean(raw, key: "select")
      return NormalizedArgumentsV1(values: [
        "count": .uint64(count),
        "move": .string(move),
        "select": .string(String(select)),
      ])
    case "textKey.v1":
      try requireKeys(
        raw,
        expected: ["command", "control", "key", "option", "repeat", "shift"]
      )
      let key = try required(raw, "key")
      guard TextKeyboardContract.keys.contains(key) else {
        throw ArgumentNormalizationError.invalid("key")
      }
      let repeatCount = try boundedKeyboardCount(raw, key: "repeat")
      var values: [String: NormalizedArgumentValue] = [
        "key": .string(key),
        "repeat": .uint64(repeatCount),
      ]
      for modifier in TextKeyboardContract.modifierArgumentKeys {
        values[modifier] = .string(String(try canonicalBoolean(raw, key: modifier)))
      }
      return NormalizedArgumentsV1(values: values)
    case "utf8Text.v1":
      try requireKeys(raw, expected: ["text"])
      let text = try required(raw, "text")
      guard text.utf8.count <= 65_536 else {
        throw ArgumentNormalizationError.tooLarge("text")
      }
      return NormalizedArgumentsV1(values: ["text": .string(text)])
    case "requiredTarget.v1":
      try requireKeys(raw, expected: ["target"])
      return NormalizedArgumentsV1(
        values: ["target": .string(try boundedASCII(required(raw, "target"), key: "target"))]
      )
    case "optionalTarget.v1":
      guard Set(raw.keys).isSubset(of: ["target"]) else {
        throw ArgumentNormalizationError.unexpectedKeys
      }
      guard let target = raw["target"] else {
        return NormalizedArgumentsV1(values: [:])
      }
      return NormalizedArgumentsV1(
        values: ["target": .string(try boundedASCII(target, key: "target"))]
      )
    case "guiSavePanel.v1", "guiWindowContext.v1", "keyboardStream.v1", "pointerStream.v1":
      guard raw.count <= 32 else {
        throw ArgumentNormalizationError.tooLarge("arguments")
      }
      var values: [String: NormalizedArgumentValue] = [:]
      for (key, value) in raw {
        values[try boundedASCII(key, key: "argument key")] = .string(
          try boundedUTF8(value, key: key, maximumBytes: 65_536)
        )
      }
      return NormalizedArgumentsV1(values: values)
    default:
      throw ArgumentNormalizationError.invalid("argumentSchemaID")
    }
  }

  private static func normalizedPath(
    _ raw: [String: String],
    key: String,
    requiredSuffix: String?
  ) throws -> NormalizedArgumentsV1 {
    try requireKeys(raw, expected: [key])
    let value = try normalizedPathValue(
      required(raw, key),
      key: key,
      requiredSuffix: requiredSuffix
    )
    return NormalizedArgumentsV1(values: [key: .string(value)])
  }

  private static func normalizedPathValue(
    _ value: String,
    key: String,
    requiredSuffix: String?
  ) throws -> String {
    guard value.hasPrefix("/"),
      !value.contains("//"),
      !value.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
      requiredSuffix == nil || value.hasSuffix(requiredSuffix!),
      (value as NSString).standardizingPath == value
    else {
      throw ArgumentNormalizationError.invalid(key)
    }
    return try boundedUTF8(value, key: key, maximumBytes: 4_096)
  }

  private static func parsePoint(
    _ value: String,
    key: String
  ) throws -> NormalizedPointV1 {
    let components = value.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 2 else {
      throw ArgumentNormalizationError.invalid(key)
    }
    let x = String(components[0])
    let y = String(components[1])
    guard let normalizedX = canonicalUnitDecimal(x) else {
      throw ArgumentNormalizationError.invalid("\(key).x")
    }
    guard let normalizedY = canonicalUnitDecimal(y) else {
      throw ArgumentNormalizationError.invalid("\(key).y")
    }
    return NormalizedPointV1(x: normalizedX, y: normalizedY)
  }

  private static func boundedKeyboardCount(
    _ raw: [String: String],
    key: String
  ) throws -> UInt64 {
    guard let value = UInt64(try required(raw, key)),
      (1...TextKeyboardContract.maximumRepeatCount).contains(value)
    else {
      throw ArgumentNormalizationError.invalid(key)
    }
    return value
  }

  private static func canonicalBoolean(
    _ raw: [String: String],
    key: String
  ) throws -> Bool {
    guard let value = TextKeyboardContract.canonicalBoolean(try required(raw, key)) else {
      throw ArgumentNormalizationError.invalid(key)
    }
    return value
  }

  private static func canonicalUnitDecimal(_ value: String) -> String? {
    guard !value.isEmpty,
      value.utf8.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x2e })
    else {
      return nil
    }
    if value == "0" || value == "1" {
      return value
    }
    if value.hasPrefix("0.") {
      let fraction = value.dropFirst(2)
      guard !fraction.isEmpty,
        fraction.utf8.count <= 18,
        fraction.utf8.allSatisfy({ (0x30...0x39).contains($0) })
      else {
        return nil
      }
      let canonicalFraction = fraction.reversed().drop(while: { $0 == "0" }).reversed()
      if canonicalFraction.isEmpty {
        return "0"
      }
      return "0." + String(canonicalFraction)
    }
    if value.hasPrefix("1.") {
      let fraction = value.dropFirst(2)
      guard !fraction.isEmpty,
        fraction.utf8.count <= 18,
        fraction.allSatisfy({ $0 == "0" })
      else {
        return nil
      }
      return "1"
    }
    return nil
  }

  private static func isValidBundleID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 255 else {
      return false
    }
    let segments = value.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else {
      return false
    }
    return segments.allSatisfy { segment in
      guard let first = segment.utf8.first,
        (first >= 0x30 && first <= 0x39)
          || (first >= 0x41 && first <= 0x5a)
          || (first >= 0x61 && first <= 0x7a)
      else {
        return false
      }
      return segment.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39)
          || ($0 >= 0x41 && $0 <= 0x5a)
          || ($0 >= 0x61 && $0 <= 0x7a)
          || $0 == 0x2d
      }
    }
  }

  private static func requireKeys(
    _ raw: [String: String],
    expected: Set<String>
  ) throws {
    guard Set(raw.keys) == expected else {
      throw ArgumentNormalizationError.unexpectedKeys
    }
  }

  private static func required(_ raw: [String: String], _ key: String) throws -> String {
    guard let value = raw[key] else {
      throw ArgumentNormalizationError.missing(key)
    }
    return value
  }

  private static func boundedASCII(_ value: String, key: String) throws -> String {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty,
      bytes.count <= 256,
      bytes.allSatisfy({ (0x21...0x7e).contains($0) })
    else {
      throw ArgumentNormalizationError.invalid(key)
    }
    return value
  }

  private static func boundedUTF8(
    _ value: String,
    key: String,
    maximumBytes: Int
  ) throws -> String {
    guard value.utf8.count <= maximumBytes else {
      throw ArgumentNormalizationError.tooLarge(key)
    }
    return value
  }
}
