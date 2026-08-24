import Foundation
import PulsePhoneSharedDefinitions

struct AppListCommandResult: Encodable, Equatable, Sendable {
    let apps: [AppListCommandItem]
    let truncated: Bool

    init?(repositoryValue: RepositoryJSONValue) {
        guard let object = repositoryValue.objectValue,
              Set(object.members.map(\.key)) == ["apps", "truncated"],
              case .bool(false)? = object["truncated"],
              let values = object["apps"]?.arrayValue
        else { return nil }
        var parsed = [AppListCommandItem]()
        var previousBundleID: String?
        for value in values {
            guard let item = AppListCommandItem(repositoryValue: value),
                  previousBundleID.map({
                      $0.utf8.lexicographicallyPrecedes(item.bundleID.utf8)
                  }) ?? true
            else {
                return nil
            }
            parsed.append(item)
            previousBundleID = item.bundleID
        }
        apps = parsed
        truncated = false
    }

    var humanTable: String {
        let header = "NAME\tBUNDLE ID\tVERSION\tTYPE"
        let rows = apps.map { app in
            [
                Self.humanField(app.displayName),
                Self.humanField(app.bundleID),
                Self.humanField(app.version),
                Self.humanField(app.applicationType),
            ].joined(separator: "\t")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func humanField(_ value: String?) -> String {
        guard let value else { return "unknown" }
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                escaped += "\\\\"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0D:
                escaped += "\\r"
            default:
                if scalar.properties.generalCategory == .control {
                    escaped += scalar.value <= 0xFFFF
                        ? String(format: "\\u%04X", scalar.value)
                        : String(format: "\\U%08X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}

struct AppListCommandItem: Encodable, Equatable, Sendable {
    let bundleID: String
    let displayName: String?
    let version: String?
    let applicationType: String

    init?(repositoryValue: RepositoryJSONValue) {
        guard let object = repositoryValue.objectValue,
              let bundleID = object["bundleID"]?.stringValue,
              Self.validBundleID(bundleID),
              let applicationType = object["applicationType"]?.stringValue,
              ["system", "unknown", "user"].contains(applicationType)
        else { return nil }
        let keys = Set(object.members.map(\.key))
        guard keys.isSubset(of: [
            "applicationType", "bundleID", "displayName", "version",
        ]),
        keys.contains("applicationType"),
        keys.contains("bundleID")
        else { return nil }
        for key in ["displayName", "version"] where object[key] != nil {
            guard let value = object[key]?.stringValue, !value.isEmpty else {
                return nil
            }
        }
        self.bundleID = bundleID
        self.displayName = object["displayName"]?.stringValue
        self.version = object["version"]?.stringValue
        self.applicationType = applicationType
    }

    private static func validBundleID(_ value: String) -> Bool {
        1...255 ~= value.utf8.count
    }
}
