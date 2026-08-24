public enum PerformanceEvaluationOutcomeV1: String, Equatable, Sendable {
    case failed
    case passed
    case unknown

    static func aggregate(_ outcomes: [Self]) -> Self {
        if outcomes.contains(.failed) { return .failed }
        if outcomes.contains(.unknown) { return .unknown }
        return .passed
    }
}

public struct PerformanceThresholdRuleV1: Equatable, Sendable {
    public let ruleID: String
    public let requirementID: String
    public let metricID: String
    public let statisticID: String
    public let applicability: PerformanceApplicabilityV1
    public let comparator: PerformanceComparatorV1?
    public let canonicalUnitID: String?
    public let limitScaledValue: Int64?
    public let notApplicableReasonCode: String?

    public init(
        ruleID: String,
        requirementID: String,
        metricID: String,
        statisticID: String,
        applicability: PerformanceApplicabilityV1,
        comparator: PerformanceComparatorV1? = nil,
        canonicalUnitID: String? = nil,
        limitScaledValue: Int64? = nil,
        notApplicableReasonCode: String? = nil
    ) throws {
        switch applicability {
        case .applicable:
            guard comparator != nil,
                  canonicalUnitID?.isEmpty == false,
                  limitScaledValue != nil,
                  notApplicableReasonCode == nil
            else {
                throw PerformanceContractError.invalidApplicability
            }
        case .notApplicable:
            guard comparator == nil,
                  canonicalUnitID == nil,
                  limitScaledValue == nil,
                  notApplicableReasonCode?.isEmpty == false
            else {
                throw PerformanceContractError.invalidApplicability
            }
        }
        self.ruleID = ruleID
        self.requirementID = requirementID
        self.metricID = metricID
        self.statisticID = statisticID
        self.applicability = applicability
        self.comparator = comparator
        self.canonicalUnitID = canonicalUnitID
        self.limitScaledValue = limitScaledValue
        self.notApplicableReasonCode = notApplicableReasonCode
    }
}

public struct PerformanceRuleEvaluationV1: Equatable, Sendable {
    public let ruleID: String
    public let metricID: String
    public let statisticID: String
    public let canonicalUnitID: String
    public let observedScaledValue: Int64?
    public let limitScaledValue: Int64?
    public let comparator: PerformanceComparatorV1?
    public let applicability: PerformanceApplicabilityV1
    public let outcome: PerformanceEvaluationOutcomeV1
    public let reasonCode: String?
}

public struct PerformanceEvaluationResultV1: Equatable, Sendable {
    public let ruleResults: [PerformanceRuleEvaluationV1]
    public let overallOutcome: PerformanceEvaluationOutcomeV1
}

public enum PerformanceEvaluatorV1 {
    public static func evaluate(
        registry: PerformanceMetricRegistryV1,
        gateValues: [PerformanceGateValueV1],
        thresholdRules: [PerformanceThresholdRuleV1]
    ) throws -> PerformanceEvaluationResultV1 {
        let gateRuleIDs = gateValues.map(\.ruleID)
        let thresholdRuleIDs = thresholdRules.map(\.ruleID)
        guard gateRuleIDs == registry.requiredRuleIDs,
              thresholdRuleIDs == registry.requiredRuleIDs,
              Set(gateRuleIDs).count == gateRuleIDs.count,
              Set(thresholdRuleIDs).count == thresholdRuleIDs.count
        else {
            throw PerformanceContractError.unsortedIdentifiers
        }
        let gates = Dictionary(uniqueKeysWithValues: gateValues.map { ($0.ruleID, $0) })
        var results = [PerformanceRuleEvaluationV1]()
        for rule in thresholdRules {
            guard let gate = gates[rule.ruleID],
                  let (metric, statisticID) = registry.rule(ruleID: rule.ruleID),
                  rule.metricID == metric.metricID,
                  rule.statisticID == statisticID,
                  gate.metricID == metric.metricID,
                  gate.statisticID == statisticID,
                  gate.canonicalUnitID == metric.canonicalUnitID
            else {
                throw PerformanceContractError.invalidRule(rule.ruleID)
            }
            results.append(evaluate(rule: rule, gate: gate, metric: metric))
        }
        return PerformanceEvaluationResultV1(
            ruleResults: results,
            overallOutcome: .aggregate(results.map(\.outcome))
        )
    }

    private static func evaluate(
        rule: PerformanceThresholdRuleV1,
        gate: PerformanceGateValueV1,
        metric: PerformanceMetricDescriptorV1
    ) -> PerformanceRuleEvaluationV1 {
        let outcome: PerformanceEvaluationOutcomeV1
        let reason: String?
        if gate.applicability != rule.applicability {
            outcome = .unknown
            reason = "applicabilityMismatch"
        } else if rule.applicability == .notApplicable {
            if gate.dataQuality == .complete,
               gate.notApplicableReasonCode == rule.notApplicableReasonCode
            {
                outcome = .passed
                reason = nil
            } else {
                outcome = .unknown
                reason = "notApplicableAuthorityMismatch"
            }
        } else if gate.dataQuality != .complete {
            outcome = .unknown
            reason = gate.unknownReasonCode ?? "metricsGap"
        } else if rule.comparator != metric.comparator
                    || rule.canonicalUnitID != metric.canonicalUnitID
        {
            outcome = .unknown
            reason = "thresholdContractMismatch"
        } else if let observed = gate.observedScaledValue,
                  let limit = rule.limitScaledValue,
                  let comparator = rule.comparator
        {
            switch comparator {
            case .greaterThanOrEqual:
                outcome = observed >= limit ? .passed : .failed
            case .lessThanOrEqual:
                outcome = observed <= limit ? .passed : .failed
            }
            reason = outcome == .failed ? "thresholdExceeded" : nil
        } else {
            outcome = .unknown
            reason = "missingComparableValue"
        }
        return PerformanceRuleEvaluationV1(
            ruleID: rule.ruleID,
            metricID: rule.metricID,
            statisticID: rule.statisticID,
            canonicalUnitID: metric.canonicalUnitID,
            observedScaledValue: gate.observedScaledValue,
            limitScaledValue: rule.limitScaledValue,
            comparator: rule.comparator,
            applicability: rule.applicability,
            outcome: outcome,
            reasonCode: reason
        )
    }
}
