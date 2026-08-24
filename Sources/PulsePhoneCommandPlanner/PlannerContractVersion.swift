import PulsePhoneCommandCatalog

public enum PlannerContractVersion {
  public static let current = "planner-contract.v5-20260805"

  public static func identity(version: String = current) -> PlannerContractIdentity {
    PlannerContractIdentity(
      plannerContractVersion: version,
      rules: [
        PlannerRuleIdentity(
          parameters: [
            "bundleIDMaximumBytes": .uint64(255),
            "gestureDurationMaximumMs": .uint64(30_000),
            "gestureDurationMinimumMs": .uint64(1),
            "pathMaximumBytes": .uint64(4_096),
            "pointFractionMaximumDigits": .uint64(18),
            "supportedSchemaIDs": .stringSet([
              "bundleID.v1", "elementSnapshot.v1", "guiSavePanel.v1", "guiWindowContext.v1",
              "ipaPath.v1", "keyboardStream.v1", "linearGesture.v1", "none.v1",
              "normalizedPoint.v1", "optionalTarget.v1", "outputPath.v1",
              "pointerStream.v1", "requiredTarget.v1", "rotateDirection.v1",
              "rotateDirection.v2", "textCursor.v1", "textKey.v1", "utf8Text.v1",
            ]),
            "textKeyboardCountMaximum": .uint64(100),
            "textMaximumBytes": .uint64(65_536),
          ],
          ruleID: "planner.argument-normalizer.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "deviceClass": .string("iPhone"),
            "missingFactsDisposition": .string("unknown"),
            "transportMatch": .string("intersection"),
          ],
          ruleID: "planner.compatibility-evaluator.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "candidateOrder": .string("declared"),
            "coreDeviceMinimumOSMajor": .uint64(17),
            "directMinimumOSMajor": .uint64(14),
            "legacyMaximumOSMajorExclusive": .uint64(17),
            "legacyMinimumOSMajor": .uint64(14),
          ],
          ruleID: "planner.candidate-selection.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "bundleIDPlaceholder": .string("{bundleID}"),
            "candidateClaimFamilies": .stringSet([
              "coredevice-input-channel", "developer-environment",
              "direct-process-slot", "oneshot-capacity-slot",
            ]),
            "deduplicateClaims": .bool(true),
          ],
          ruleID: "planner.claim-resolver.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "catalogAvailability": .string("command-presence"),
            "effectiveAvailability": .string("condition-capability-activation"),
            "preparableOneShot": .bool(true),
            "preparableStream": .bool(false),
          ],
          ruleID: "planner.effective-availability.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "requiredCommitState": .string("notCommitted"),
            "requiredDisposition": .string("safe"),
            "requiresImmediateNextClaims": .bool(true),
          ],
          ruleID: "planner.fallback-selection.v1",
          ruleVersion: 1
        ),
        PlannerRuleIdentity(
          parameters: [
            "completionMode": .string("resumePlanning"),
            "contextSource": .string("refreshed"),
          ],
          ruleID: "planner.resume-planning.v1",
          ruleVersion: 1
        ),
      ]
    )
  }
}
