import Foundation
import PulsePhoneCommandPlanner

public enum CLIHelpRequest: Equatable, Sendable {
    case commandPath(String)
    case topLevel
}

public struct CLIHelpRenderer: Sendable {
    private let surface: CLIStaticSurface

    public init(surface: CLIStaticSurface) {
        self.surface = surface
    }

    public func render(_ request: CLIHelpRequest) throws -> String {
        switch request {
        case .topLevel:
            return topLevel()
        case .commandPath(let path):
            return try command(path: path)
        }
    }

    public func commandTable() -> String {
        surface.groups.compactMap { group in
            let variants = surface.variants.filter { $0.groupID == group.groupID }
                .sorted { lhs, rhs in
                    if lhs.commandPath != rhs.commandPath {
                        return lhs.commandPath.utf8.lexicographicallyPrecedes(
                            rhs.commandPath.utf8
                        )
                    }
                    return lhs.cliVariant.utf8.lexicographicallyPrecedes(rhs.cliVariant.utf8)
                }
            guard !variants.isEmpty else { return nil }
            let rows = variants.map { variant in
                "  \(usage(variant))\n      \(variant.summary) [\(compatibility(variant.compatibility))]"
            }
            return ([group.title + ":"] + rows).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func topLevel() -> String {
        let global = surface.globalOptions.map { option in
            "  \(optionUsage(option))\n      \(option.summary)"
        }.joined(separator: "\n")
        return [
            "PulsePhone",
            "",
            "Usage:",
            "  PulsePhone <command> [options]",
            "  PulsePhone help",
            "  PulsePhone --help",
            "",
            "Commands:",
            commandTable(),
            "",
            "Global options:",
            global,
        ].joined(separator: "\n")
    }

    private func command(path: String) throws -> String {
        let variants = surface.variants(commandPath: path).sorted {
            $0.cliVariant.utf8.lexicographicallyPrecedes($1.cliVariant.utf8)
        }
        guard !variants.isEmpty else {
            throw CLIArgumentPreflightError.unknownCommand(path)
        }
        let usageLines = variants.map { "  \(usage($0))" }
        let summaries = variants.map { variant in
            "  \(variant.cliVariant): \(variant.summary)"
        }
        let options = Dictionary(
            variants.flatMap(\.options).map { ($0.spelling, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            $0.spelling.utf8.lexicographicallyPrecedes($1.spelling.utf8)
        }
        let rendersTextKeyAllowlist = variants.contains {
            $0.commandID == "text.key"
        }
        let optionLines = options.flatMap { option -> [String] in
            if rendersTextKeyAllowlist, option.spelling == "--key" {
                return textKeyOptionLines(option)
            }
            var detail = "      \(option.summary)"
            if let constraint = option.constraint {
                detail += " Constraint: \(constraint)"
            }
            return ["  \(optionUsage(option))", detail]
        }
        let compatibilityLines = variants.map { variant in
            var lines = ["  \(variant.cliVariant): \(compatibility(variant.compatibility))"]
            lines += variant.compatibility.supportVariants.map { support in
                "      \(support.preparationGroupID): \(supportCompatibility(support))"
            }
            return lines.joined(separator: "\n")
        }
        let examples = Array(Set(variants.flatMap(\.examples))).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }.map { "  \($0)" }
        var sections = [
            "PulsePhone \(path)",
            "",
            "Usage:",
            usageLines.joined(separator: "\n"),
            "",
            "Description:",
            summaries.joined(separator: "\n"),
        ]
        if !optionLines.isEmpty {
            sections += ["", "Options:", optionLines.joined(separator: "\n")]
        }
        sections += [
            "",
            "Compatibility:",
            compatibilityLines.joined(separator: "\n"),
        ]
        if !examples.isEmpty {
            sections += ["", "Examples:", examples.joined(separator: "\n")]
        }
        return sections.joined(separator: "\n")
    }

    private func textKeyOptionLines(_ option: CLICommandOption) -> [String] {
        [
            "  \(optionUsage(option))",
            "      \(option.summary)",
            "      Allowed values:",
        ] + wrappedValues(label: "Letters", values: TextKeyboardContract.letterKeys)
            + wrappedValues(label: "Digits", values: TextKeyboardContract.digitKeys)
            + wrappedValues(label: "Editing", values: TextKeyboardContract.editingKeys)
            + wrappedValues(
                label: "Punctuation",
                values: TextKeyboardContract.punctuationKeys
            )
            + wrappedValues(
                label: "Navigation",
                values: TextKeyboardContract.navigationKeys
            )
            + wrappedValues(label: "Other", values: TextKeyboardContract.otherKeys)
    }

    private func wrappedValues(label: String, values: [String]) -> [String] {
        let firstPrefix = "        \(label): "
        let continuationPrefix = String(repeating: " ", count: firstPrefix.count)
        var lines = [String]()
        var current = firstPrefix
        for value in values {
            let separator = current == firstPrefix ? "" : ", "
            if current.utf8.count + separator.utf8.count + value.utf8.count > 88,
               current != firstPrefix
            {
                lines.append(current)
                current = continuationPrefix + value
            } else {
                current += separator + value
            }
        }
        lines.append(current)
        return lines
    }

    private func usage(_ variant: CLICommandVariant) -> String {
        let options = variant.options.map { option -> String in
            let rendered = optionUsage(option)
            return option.required ? rendered : "[\(rendered)]"
        }
        return (["PulsePhone", variant.commandPath] + options).joined(separator: " ")
    }

    private func optionUsage(_ option: CLICommandOption) -> String {
        let base: String
        if let valueName = option.valueName {
            base = "\(option.spelling) <\(valueName)>"
        } else {
            base = option.spelling
        }
        return option.repeatable ? base + "..." : base
    }

    private func compatibility(_ value: CLICompatibilityPresentation) -> String {
        if !value.deviceRequired {
            return "macOS local; no device required"
        }
        return [
            osRange(minimum: value.minimumOSMajor, maximum: value.maximumOSMajorExclusive),
            transport(value.transportIDs),
        ].compactMap { $0 }.joined(separator: "; ")
    }

    private func supportCompatibility(_ value: CLICompatibilitySupportVariant) -> String {
        var parts = [
            osRange(minimum: value.minimumOSMajor, maximum: value.maximumOSMajorExclusive),
            transport(value.transportIDs),
        ].compactMap { $0 }
        if let route = value.route, route != "none" {
            parts.append(routeLabel(route))
        }
        return parts.joined(separator: "; ")
    }

    private func osRange(minimum: UInt64?, maximum: UInt64?) -> String? {
        switch (minimum, maximum) {
        case let (.some(minimum), .some(maximum)) where maximum > minimum:
            return maximum == minimum + 1
                ? "iOS \(minimum)"
                : "iOS \(minimum)-\(maximum - 1)"
        case let (.some(minimum), .none):
            return "iOS \(minimum)+"
        case let (.none, .some(maximum)):
            return "iOS before \(maximum)"
        default:
            return nil
        }
    }

    private func transport(_ identifiers: [String]) -> String? {
        if identifiers.contains("usb") { return "USB iPhone" }
        if identifiers.contains("rsd") { return "USB iPhone via CoreDevice" }
        return identifiers.isEmpty ? "connected iPhone" : identifiers.joined(separator: ", ")
    }

    private func routeLabel(_ route: String) -> String {
        switch route {
        case "classic": return "classic Developer Support"
        case "personalized": return "personalized Developer Support"
        default: return route
        }
    }
}
