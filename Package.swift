// swift-tools-version: 6.0

import PackageDescription

let sharedTargets: [Target.Dependency] = [
    "PulsePhoneSharedDefinitions",
    "PulsePhoneCommandCatalog",
    "PulsePhoneCommandPlanner",
    "PulsePhoneAvailability",
    "PulsePhoneWire",
    "PulsePhoneHostPaths",
    "PulsePhoneDeveloperSupportDefinitions",
]

let package = Package(
    name: "PulsePhone",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "PulsePhone", targets: ["PulsePhoneExecutable"]),
        .executable(name: "PulsePhoneRuntime", targets: ["PulsePhoneRuntimeExecutable"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PulsePhoneExecutable",
            dependencies: [
                "PulsePhoneCLI",
                "PulsePhoneGUI",
                "PulsePhoneClientCore",
                "PulsePhoneMedia",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneCLI",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneLogging",
                "PulsePhoneRuntimeKernel",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneGUI",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneBackendAdapters",
                "PulsePhoneCommandPlanner",
                "PulsePhoneHostPaths",
                "PulsePhoneMedia",
                "PulsePhoneLogging",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
                "PulsePhoneCommandCatalog",
                "PulsePhoneAvailability",
                "PulsePhoneWire",
            ]
        ),
        .target(
            name: "PulsePhoneClientCore",
            dependencies: [
                "PulsePhoneLogging",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneMedia",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneLogging",
                "PulsePhoneSharedDefinitions",
            ]
        ),
        .target(
            name: "PulsePhoneElement",
            dependencies: [
                "PulsePhoneMedia",
                "PulsePhoneSharedDefinitions",
            ]
        ),
        .target(
            name: "PulsePhoneAppleRegionBridge",
            path: "Sources/PulsePhoneAppleRegionBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .target(name: "PulsePhoneSharedDefinitions"),
        .target(
            name: "PulsePhoneCommandCatalog",
            dependencies: ["PulsePhoneSharedDefinitions"]
        ),
        .target(
            name: "PulsePhoneCommandPlanner",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneCommandCatalog",
                "PulsePhoneDeveloperSupportDefinitions",
            ]
        ),
        .target(
            name: "PulsePhoneAvailability",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneDeveloperSupportDefinitions",
            ]
        ),
        .target(
            name: "PulsePhoneWire",
            dependencies: ["PulsePhoneSharedDefinitions"]
        ),
        .target(
            name: "PulsePhoneHostPaths",
            dependencies: ["PulsePhoneSharedDefinitions"]
        ),
        .target(
            name: "PulsePhoneDeveloperSupportDefinitions",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneCommandCatalog",
                "PulsePhoneWire",
            ]
        ),
        .executableTarget(
            name: "PulsePhoneRuntimeExecutable",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
                "PulsePhoneBackendAdapters",
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneLogging",
                "PulsePhoneElement",
                "PulsePhoneAppleRegionBridge",
                "PulsePhoneMedia",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneRuntimeKernel",
            dependencies: [
                "PulsePhoneRuntimeState",
                "PulsePhoneLogging",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneRuntimeState",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneAvailability",
                "PulsePhoneWire",
                "PulsePhoneDeveloperSupportDefinitions",
            ]
        ),
        .target(
            name: "PulsePhoneBackendAdapters",
            dependencies: [
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneLogging",
            ] + sharedTargets
        ),
        .target(
            name: "PulsePhoneDeveloperImageAssets",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneHostPaths",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneLogging",
            ]
        ),
        .target(
            name: "PulsePhoneLogging",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneHostPaths",
            ]
        ),
        .testTarget(
            name: "PulsePhoneSharedDefinitionsTests",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/SharedDefinitionsTests"
        ),
        .testTarget(
            name: "PulsePhoneMediaTests",
            dependencies: [
                "PulsePhoneMedia",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/MediaTests"
        ),
        .testTarget(
            name: "PulsePhoneElementTests",
            dependencies: [
                "PulsePhoneElement",
                "PulsePhoneMedia",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/ElementTests"
        ),
        .testTarget(
            name: "PulsePhoneCLIContractTests",
            dependencies: [
                "PulsePhoneCLI",
                "PulsePhoneClientCore",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/CLIContractTests"
        ),
        .testTarget(
            name: "PulsePhoneHostPathsTests",
            dependencies: [
                "PulsePhoneHostPaths",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/HostPathTests"
        ),
        .testTarget(
            name: "PulsePhoneEvidenceContractTests",
            dependencies: [
                "PulsePhoneHostPaths",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/EvidenceContractTests"
        ),
        .testTarget(
            name: "PulsePhoneCommandCatalogTests",
            dependencies: [
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/CommandCatalogTests"
        ),
        .testTarget(
            name: "PulsePhonePlannerTests",
            dependencies: [
                "PulsePhoneAvailability",
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/PlannerTests"
        ),
        .testTarget(
            name: "PulsePhoneDeveloperImageCatalogTests",
            dependencies: [
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/DeveloperImageCatalogTests"
        ),
        .testTarget(
            name: "PulsePhoneRegistryContractTests",
            dependencies: [
                "PulsePhoneSharedDefinitions",
                "PulsePhoneWire",
            ],
            path: "Tests/Unit/RegistryContractTests"
        ),
        .testTarget(
            name: "PulsePhoneWireCodecTests",
            dependencies: [
                "PulsePhoneRuntimeKernel",
                "PulsePhoneSharedDefinitions",
                "PulsePhoneWire",
            ],
            path: "Tests/Unit/WireCodecTests"
        ),
        .testTarget(
            name: "PulsePhoneLifecycleTests",
            dependencies: [
                "PulsePhoneCommandPlanner",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/LifecycleTests"
        ),
        .testTarget(
            name: "PulsePhoneLoggingTests",
            dependencies: [
                "PulsePhoneCLI",
                "PulsePhoneClientCore",
                "PulsePhoneLogging",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/LoggingTests"
        ),
        .testTarget(
            name: "PulsePhoneSchedulerTests",
            dependencies: [
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Unit/SchedulerTests"
        ),
        .testTarget(
            name: "PulsePhonePreparationCoordinatorTests",
            dependencies: [
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
                "PulsePhoneWire",
            ],
            path: "Tests/Unit/PreparationCoordinatorTests"
        ),
        .testTarget(
            name: "PulsePhoneRuntimeBootstrapTests",
            dependencies: [
                "PulsePhoneCLI",
                "PulsePhoneClientCore",
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneHostPaths",
                "PulsePhoneElement",
                "PulsePhoneMedia",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeExecutable",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/RuntimeBootstrapTests"
        ),
        .testTarget(
            name: "PulsePhoneHelperSupervisorTests",
            dependencies: [
                "PulsePhoneClientCore",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneSharedDefinitions",
                "PulsePhoneWire",
            ],
            path: "Tests/Integration/HelperSupervisorTests"
        ),
        .testTarget(
            name: "PulsePhoneDeveloperSupportHelperTests",
            dependencies: [
                "PulsePhoneBackendAdapters",
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/DeveloperSupportHelperTests"
        ),
        .testTarget(
            name: "PulsePhoneDeveloperImageAssetStoreTests",
            dependencies: [
                "PulsePhoneDeveloperImageAssets",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/DeveloperImageAssetStoreTests"
        ),
        .testTarget(
            name: "PulsePhoneArtifactFDTests",
            dependencies: [
                "PulsePhoneHostPaths",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/ArtifactFDTests"
        ),
        .testTarget(
            name: "PulsePhoneGUIHostTests",
            dependencies: [
                "PulsePhoneGUI",
                "PulsePhoneHostPaths",
                "PulsePhoneMedia",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/GUIHostTests"
        ),
        .testTarget(
            name: "PulsePhoneProductActionTests",
            dependencies: [
                "PulsePhoneBackendAdapters",
                "PulsePhoneCLI",
                "PulsePhoneClientCore",
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneGUI",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/ProductActionTests"
        ),
        .testTarget(
            name: "PulsePhoneProductMatrixTests",
            dependencies: [
                "PulsePhoneBackendAdapters",
                "PulsePhoneCLI",
                "PulsePhoneCommandCatalog",
                "PulsePhoneCommandPlanner",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Integration/ProductMatrixTests",
            exclude: ["product_matrix.py"]
        ),
        .testTarget(
            name: "PulsePhonePackagingTests",
            path: "Tests/Integration/PackagingTests"
        ),
        .testTarget(
            name: "PulsePhonePerformanceTests",
            dependencies: [
                "PulsePhoneMedia",
                "PulsePhoneSharedDefinitions",
            ],
            path: "Tests/Performance"
        ),
        .testTarget(
            name: "PulsePhoneFaultInjectionTests",
            dependencies: [
                "PulsePhoneBackendAdapters",
                "PulsePhoneCLI",
                "PulsePhoneClientCore",
                "PulsePhoneCommandCatalog",
                "PulsePhoneDeveloperSupportDefinitions",
                "PulsePhoneGUI",
                "PulsePhoneMedia",
                "PulsePhoneRuntimeKernel",
                "PulsePhoneRuntimeState",
                "PulsePhoneSharedDefinitions",
                "PulsePhoneWire",
            ],
            path: "Tests/Integration/FaultInjectionTests"
        ),
    ]
)
