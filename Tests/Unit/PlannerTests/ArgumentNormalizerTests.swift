import Foundation
import XCTest

@testable import PulsePhoneCommandPlanner

private struct ArgumentFixture: Decodable {
  struct FixtureCase: Decodable {
    let caseID: String
    let expectedOutcome: String
    let expectedValues: [String: String]
    let raw: [String: String]
    let schemaID: String
  }

  let cases: [FixtureCase]
  let schemaVersion: UInt64
}

final class ArgumentNormalizerTests: XCTestCase {
  func testCanonicalFixtureCases() throws {
    let fixture: ArgumentFixture = try loadPlannerFixture(
      "argument-normalization.v1.json"
    )
    XCTAssertEqual(fixture.schemaVersion, 1)
    for fixtureCase in fixture.cases {
      if fixtureCase.expectedOutcome == "valid" {
        let normalized = try ArgumentNormalizer.normalize(
          schemaID: fixtureCase.schemaID,
          raw: fixtureCase.raw
        )
        XCTAssertEqual(serialized(normalized), fixtureCase.expectedValues, fixtureCase.caseID)
      } else {
        XCTAssertThrowsError(
          try ArgumentNormalizer.normalize(
            schemaID: fixtureCase.schemaID,
            raw: fixtureCase.raw
          ),
          fixtureCase.caseID
        )
      }
    }
  }

  func testCapsAndUnknownSchemasFailClosed() {
    XCTAssertThrowsError(
      try ArgumentNormalizer.normalize(
        schemaID: "utf8Text.v1",
        raw: ["text": String(repeating: "x", count: 65_537)]
      )
    )
    XCTAssertThrowsError(
      try ArgumentNormalizer.normalize(
        schemaID: "none.v1",
        raw: ["extra": "value"]
      )
    )
    XCTAssertThrowsError(
      try ArgumentNormalizer.normalize(schemaID: "unknown.v1", raw: [:])
    )
  }

  func testTextKeyboardSchemasNormalizeBoundedSemanticArguments() throws {
    let key = try ArgumentNormalizer.normalize(
      schemaID: "textKey.v1",
      raw: [
        "command": "true", "control": "false", "key": "a",
        "option": "true", "repeat": "100", "shift": "false",
      ]
    )
    XCTAssertEqual(serialized(key), [
      "command": "string:true", "control": "string:false", "key": "string:a",
      "option": "string:true", "repeat": "uint64:100", "shift": "string:false",
    ])

    let cursor = try ArgumentNormalizer.normalize(
      schemaID: "textCursor.v1",
      raw: ["count": "1", "move": "document-end", "select": "true"]
    )
    XCTAssertEqual(serialized(cursor), [
      "count": "uint64:1", "move": "string:document-end", "select": "string:true",
    ])
  }

  func testTextKeyboardSchemasRejectUnknownUnboundedAndNoncanonicalValues() {
    let invalid: [(String, [String: String])] = [
      ("textKey.v1", [
        "command": "false", "control": "false", "key": "A",
        "option": "false", "repeat": "1", "shift": "false",
      ]),
      ("textKey.v1", [
        "command": "false", "control": "false", "key": "a",
        "option": "false", "repeat": "0", "shift": "false",
      ]),
      ("textKey.v1", [
        "command": "false", "control": "false", "key": "a",
        "option": "false", "repeat": "101", "shift": "false",
      ]),
      ("textKey.v1", [
        "command": "False", "control": "false", "key": "a",
        "option": "false", "repeat": "1", "shift": "false",
      ]),
      ("textCursor.v1", ["count": "1", "move": "character-left", "select": "false"]),
      ("textCursor.v1", ["count": "101", "move": "left", "select": "false"]),
      ("textCursor.v1", [
        "count": "1", "extra": "value", "move": "left", "select": "false",
      ]),
    ]
    for (schemaID, raw) in invalid {
      XCTAssertThrowsError(
        try ArgumentNormalizer.normalize(schemaID: schemaID, raw: raw),
        "\(schemaID): \(raw)"
      )
    }
  }

  private func serialized(_ arguments: NormalizedArgumentsV1) -> [String: String] {
    arguments.values.mapValues { value in
      switch value {
      case .point(let point):
        return "point:\(point.x),\(point.y)"
      case .string(let string):
        return "string:\(string)"
      case .uint64(let number):
        return "uint64:\(number)"
      }
    }
  }
}
