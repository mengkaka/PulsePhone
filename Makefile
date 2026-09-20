SHELL = /bin/sh

EXPECTED_TARGET_RECORDS = \
	PulsePhoneAppleRegionBridge\|library\|Sources/PulsePhoneAppleRegionBridge\| \
	PulsePhoneAvailability\|library\|Sources/PulsePhoneAvailability\|PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions \
	PulsePhoneArtifactFDTests\|test\|Tests/Integration/ArtifactFDTests\|PulsePhoneHostPaths,PulsePhoneRuntimeKernel,PulsePhoneSharedDefinitions \
	PulsePhoneBackendAdapters\|library\|Sources/PulsePhoneBackendAdapters\|PulsePhoneAvailability,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneCLIContractTests\|test\|Tests/Unit/CLIContractTests\|PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneHostPaths,PulsePhoneSharedDefinitions \
	PulsePhoneCLI\|library\|Sources/PulsePhoneCLI\|PulsePhoneAvailability,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneElement,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneRuntimeKernel,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneClientCore\|library\|Sources/PulsePhoneClientCore\|PulsePhoneAvailability,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneCommandCatalog\|library\|Sources/PulsePhoneCommandCatalog\|PulsePhoneSharedDefinitions \
	PulsePhoneCommandCatalogTests\|test\|Tests/Unit/CommandCatalogTests\|PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneSharedDefinitions \
	PulsePhoneCommandPlanner\|library\|Sources/PulsePhoneCommandPlanner\|PulsePhoneCommandCatalog,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions \
	PulsePhoneDeveloperImageAssetStoreTests\|test\|Tests/Integration/DeveloperImageAssetStoreTests\|PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions \
	PulsePhoneDeveloperImageAssets\|library\|Sources/PulsePhoneDeveloperImageAssets\|PulsePhoneDeveloperSupportDefinitions,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneSharedDefinitions \
	PulsePhoneDeveloperImageCatalogTests\|test\|Tests/Unit/DeveloperImageCatalogTests\|PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions \
	PulsePhoneDeveloperSupportHelperTests\|test\|Tests/Integration/DeveloperSupportHelperTests\|PulsePhoneBackendAdapters,PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions \
	PulsePhoneDeveloperSupportDefinitions\|library\|Sources/PulsePhoneDeveloperSupportDefinitions\|PulsePhoneCommandCatalog,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneElementTests\|test\|Tests/Unit/ElementTests\|PulsePhoneElement,PulsePhoneHostPaths,PulsePhoneMedia,PulsePhoneSharedDefinitions \
	PulsePhoneElement\|library\|Sources/PulsePhoneElement\|PulsePhoneHostPaths,PulsePhoneMedia,PulsePhoneSharedDefinitions \
	PulsePhoneExecutable\|executable\|Sources/PulsePhoneExecutable\|PulsePhoneAvailability,PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneGUI,PulsePhoneHostPaths,PulsePhoneMedia,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneGUI\|library\|Sources/PulsePhoneGUI\|PulsePhoneAvailability,PulsePhoneBackendAdapters,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneMedia,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneGUIHostTests\|test\|Tests/Integration/GUIHostTests\|PulsePhoneGUI,PulsePhoneHostPaths,PulsePhoneMedia,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions \
	PulsePhoneEvidenceContractTests\|test\|Tests/Unit/EvidenceContractTests\|PulsePhoneHostPaths,PulsePhoneSharedDefinitions \
	PulsePhoneFaultInjectionTests\|test\|Tests/Integration/FaultInjectionTests\|PulsePhoneBackendAdapters,PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneDeveloperSupportDefinitions,PulsePhoneGUI,PulsePhoneMedia,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneHostPathsTests\|test\|Tests/Unit/HostPathTests\|PulsePhoneHostPaths,PulsePhoneSharedDefinitions \
	PulsePhoneHostPaths\|library\|Sources/PulsePhoneHostPaths\|PulsePhoneSharedDefinitions \
	PulsePhoneHelperSupervisorTests\|test\|Tests/Integration/HelperSupervisorTests\|PulsePhoneClientCore,PulsePhoneRuntimeKernel,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneLogging\|library\|Sources/PulsePhoneLogging\|PulsePhoneHostPaths,PulsePhoneSharedDefinitions \
	PulsePhoneLoggingTests\|test\|Tests/Unit/LoggingTests\|PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneLogging,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions \
	PulsePhoneLifecycleTests\|test\|Tests/Unit/LifecycleTests\|PulsePhoneCommandPlanner,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions \
	PulsePhoneMediaTests\|test\|Tests/Unit/MediaTests\|PulsePhoneMedia,PulsePhoneSharedDefinitions \
	PulsePhoneMedia\|library\|Sources/PulsePhoneMedia\|PulsePhoneClientCore,PulsePhoneLogging,PulsePhoneSharedDefinitions \
	PulsePhonePackagingTests\|test\|Tests/Integration/PackagingTests\| \
	PulsePhonePerformanceTests\|test\|Tests/Performance\|PulsePhoneMedia,PulsePhoneSharedDefinitions \
	PulsePhonePlannerTests\|test\|Tests/Unit/PlannerTests\|PulsePhoneAvailability,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneSharedDefinitions \
	PulsePhonePreparationCoordinatorTests\|test\|Tests/Unit/PreparationCoordinatorTests\|PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneProductActionTests\|test\|Tests/Integration/ProductActionTests\|PulsePhoneBackendAdapters,PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneGUI,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions \
	PulsePhoneProductMatrixTests\|test\|Tests/Integration/ProductMatrixTests\|PulsePhoneBackendAdapters,PulsePhoneCLI,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneSharedDefinitions \
	PulsePhoneRegistryContractTests\|test\|Tests/Unit/RegistryContractTests\|PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneRuntimeBootstrapTests\|test\|Tests/Integration/RuntimeBootstrapTests\|PulsePhoneCLI,PulsePhoneClientCore,PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneElement,PulsePhoneHostPaths,PulsePhoneMedia,PulsePhoneRuntimeExecutable,PulsePhoneRuntimeKernel,PulsePhoneSharedDefinitions \
	PulsePhoneRuntimeExecutable\|executable\|Sources/PulsePhoneRuntimeExecutable\|PulsePhoneAppleRegionBridge,PulsePhoneAvailability,PulsePhoneBackendAdapters,PulsePhoneClientCore,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperImageAssets,PulsePhoneDeveloperSupportDefinitions,PulsePhoneElement,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneMedia,PulsePhoneRuntimeKernel,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneRuntimeKernel\|library\|Sources/PulsePhoneRuntimeKernel\|PulsePhoneAvailability,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneHostPaths,PulsePhoneLogging,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneRuntimeState\|library\|Sources/PulsePhoneRuntimeState\|PulsePhoneAvailability,PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneDeveloperSupportDefinitions,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneSchedulerTests\|test\|Tests/Unit/SchedulerTests\|PulsePhoneCommandCatalog,PulsePhoneCommandPlanner,PulsePhoneRuntimeState,PulsePhoneSharedDefinitions \
	PulsePhoneSharedDefinitionsTests\|test\|Tests/Unit/SharedDefinitionsTests\|PulsePhoneClientCore,PulsePhoneSharedDefinitions \
	PulsePhoneSharedDefinitions\|library\|Sources/PulsePhoneSharedDefinitions\| \
	PulsePhoneWireCodecTests\|test\|Tests/Unit/WireCodecTests\|PulsePhoneRuntimeKernel,PulsePhoneSharedDefinitions,PulsePhoneWire \
	PulsePhoneWire\|library\|Sources/PulsePhoneWire\|PulsePhoneSharedDefinitions

REQUIRED_TRACKED_FILES = \
	.gitignore \
	Package.swift \
	Makefile \
	README.md \
	Sources/PulsePhoneExecutable/main.swift \
	Sources/PulsePhoneRuntimeExecutable/main.swift

REQUIRED_MARKER_DIRS = \
	Registries \
	Schemas/wire \
	Schemas/result-schemas \
	Schemas/details-schemas \
	Schemas/developer-support \
	Schemas/evidence \
	Schemas/implementation \
	Fixtures/contracts \
	Fixtures/catalog \
	Fixtures/planner \
	Fixtures/helper-wire \
	Fixtures/facts-probe \
	Fixtures/identity \
	Fixtures/developer-support \
	Fixtures/acquisition-http \
	Fixtures/preparation-lifecycle \
	Fixtures/evidence \
	Fixtures/performance \
	Fixtures/product-actions \
	Fixtures/product-matrix \
	Fixtures/requirements \
	Fixtures/release \
	Tests/Unit/RegistryContractTests \
	Tests/Unit/PythonRegistryTests \
	Tests/Unit/EvidenceContractTests \
	Tests/Unit/CommandCatalogTests \
	Tests/Unit/PlannerTests \
	Tests/Unit/SchedulerTests \
	Tests/Unit/LifecycleTests \
	Tests/Unit/WireCodecTests \
	Tests/Unit/LoggingTests \
	Tests/Unit/DeveloperImageCatalogTests \
	Tests/Unit/PreparationCoordinatorTests \
	Tests/Unit/CLIContractTests \
	Tests/Integration/RuntimeBootstrapTests \
	Tests/Integration/HelperSupervisorTests \
	Tests/Integration/GUIHostTests \
	Tests/Integration/ArtifactFDTests \
	Tests/Integration/DeveloperImageAssetStoreTests \
	Tests/Integration/DeveloperSupportHelperTests \
	Tests/Integration/ProductMatrixTests \
	Tests/Integration/ProductActionTests \
	Tests/Integration/PackagingTests \
	Tests/Integration/FaultInjectionTests \
	Tests/Device/IOS14To16Legacy \
	Tests/Device/IOS17PlusModern \
	Tests/Performance \
	Packaging/manifests \
	Packaging/licenses \
	Packaging/scripts \
	Scripts

GATE_VARIABLES = GATE_SOURCE_POLICY_ID GATE_WRITE_GRANT GATE_NEGATIVE_REMOVAL_PLAN_RECORD GATE_THRESHOLD_FREEZE_RECORD GATE_THRESHOLD_FREEZE_HOLD

.NOTPARALLEL:

.PHONY: doctor verify-structure verify-python-tooling build test check \
	test-python verify-standard-errors verify-wire-registry \
	build-go test-go verify-generated-go verify-go-dependencies \
	verify-generated-swift verify-generated \
	verify-preparation-capture \
	verify-command-catalog-partial verify-command-matrix verify-developer-image-catalog-partial \
	verify-evidence-policy-structural verify-evidence-policy-release-complete verify-contracts-bootstrap verify-contracts-current \
	verify-m0-gate verify-m1-gate verify-m2-gate verify-negative-removal \
	verify-threshold-freeze verify-final-release-evidence verify-m3-release-gate

doctor:
	@set -eu; \
	developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	test -n "$$developer_dir"; \
	test -d "$$developer_dir"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun --find swift >/dev/null 2>&1; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift --version >/dev/null 2>&1; \
	/usr/bin/make --version | /usr/bin/sed -n '1p' | /usr/bin/grep '^GNU Make ' >/dev/null; \
	/usr/bin/git --version >/dev/null; \
	go version | /usr/bin/grep '^go version go1.26.2 ' >/dev/null; \
	/usr/bin/printf 'pulsephone-doctor.v1 state=passed\n'

build-go:
	@set -eu; \
	mkdir -p build/go/debug; \
	cd GoHelpers && \
	GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=vendor CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
	go build -trimpath -buildvcs=true -o ../build/go/debug/PulsePhoneDirectHelper ./cmd/pulsephone-direct-helper; \
	GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=vendor CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
	go build -trimpath -buildvcs=true -o ../build/go/debug/PulsePhoneCoreDeviceHelper ./cmd/pulsephone-coredevice-helper

test-go:
	@set -eu; \
	cd GoHelpers && GOENV=off GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 go test ./...

verify-generated-go:
	@Scripts/generate-registries go --verify

verify-go-dependencies:
	@set -eu; \
	cd GoHelpers; \
	GOENV=off GOWORK=off GOTOOLCHAIN=local go mod verify; \
	test "$$(GOENV=off GOWORK=off GOTOOLCHAIN=local go list -m all | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1; \
	/usr/bin/printf 'pulsephone-go-dependencies.v1 state=passed modules=stdlib\n'

verify-structure:
	@set -eu; \
	root="$$('/usr/bin/mktemp' -d -t pulsephone-structure)"; \
	trap 'rm -rf "$$root"' EXIT HUP INT TERM; \
	description="$$root/package-description.json"; \
	actual_targets="$$root/actual-targets"; \
	expected_targets="$$root/expected-targets"; \
	actual_markers="$$root/actual-markers"; \
	allowed_markers="$$root/allowed-markers"; \
	developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift package describe --type json >"$$description"; \
	test "$$('/usr/bin/plutil' -extract tools_version raw -o - "$$description")" = '6.0'; \
	test "$$('/usr/bin/plutil' -extract dependencies raw -o - "$$description")" = '0'; \
	test "$$('/usr/bin/plutil' -extract platforms raw -o - "$$description")" = '1'; \
	test "$$('/usr/bin/plutil' -extract platforms.0.name raw -o - "$$description")" = 'macos'; \
	test "$$('/usr/bin/plutil' -extract platforms.0.version raw -o - "$$description")" = '14.0'; \
	test "$$('/usr/bin/plutil' -extract products raw -o - "$$description")" = '2'; \
	{ \
		count="$$('/usr/bin/plutil' -extract products raw -o - "$$description")"; \
		i=0; \
		while test "$$i" -lt "$$count"; do \
			name="$$('/usr/bin/plutil' -extract "products.$$i.name" raw -o - "$$description")"; \
			target="$$('/usr/bin/plutil' -extract "products.$$i.targets.0" raw -o - "$$description")"; \
			/usr/bin/printf '%s|%s\n' "$$name" "$$target"; \
			i=$$((i + 1)); \
		done; \
	} | /usr/bin/sort >"$$root/actual-products"; \
	/usr/bin/printf '%s\n' 'PulsePhoneRuntime|PulsePhoneRuntimeExecutable' 'PulsePhone|PulsePhoneExecutable' | /usr/bin/sort >"$$root/expected-products"; \
	/usr/bin/diff -u "$$root/expected-products" "$$root/actual-products"; \
	{ \
		count="$$('/usr/bin/plutil' -extract targets raw -o - "$$description")"; \
		i=0; \
		while test "$$i" -lt "$$count"; do \
			name="$$('/usr/bin/plutil' -extract "targets.$$i.name" raw -o - "$$description")"; \
			type="$$('/usr/bin/plutil' -extract "targets.$$i.type" raw -o - "$$description")"; \
			path="$$('/usr/bin/plutil' -extract "targets.$$i.path" raw -o - "$$description")"; \
			if dep_count="$$('/usr/bin/plutil' -extract "targets.$$i.target_dependencies" raw -o - "$$description" 2>/dev/null)"; then :; else dep_count=0; fi; \
			deps=''; \
			j=0; \
			while test "$$j" -lt "$$dep_count"; do \
				dep="$$('/usr/bin/plutil' -extract "targets.$$i.target_dependencies.$$j" raw -o - "$$description")"; \
				deps="$${deps}$${deps:+,}$${dep}"; \
				j=$$((j + 1)); \
			done; \
			deps="$$('/usr/bin/printf' '%s\n' "$$deps" | /usr/bin/tr ',' '\n' | /usr/bin/sort | /usr/bin/paste -sd, -)"; \
			/usr/bin/printf '%s|%s|%s|%s\n' "$$name" "$$type" "$$path" "$$deps"; \
			i=$$((i + 1)); \
		done; \
	} | /usr/bin/sort >"$$actual_targets"; \
	{ for record in $(EXPECTED_TARGET_RECORDS); do /usr/bin/printf '%s\n' "$$record"; done; } | /usr/bin/sort >"$$expected_targets"; \
	/usr/bin/diff -u "$$expected_targets" "$$actual_targets"; \
	for path in $(REQUIRED_TRACKED_FILES); do \
		test -f "$$path"; \
		/usr/bin/git ls-files --error-unmatch "$$path" >/dev/null; \
	done; \
	check_leaf() { \
		dir="$$1"; \
		entries="$$('/usr/bin/git' ls-files "$$dir")"; \
		test -n "$$entries"; \
		if /usr/bin/git ls-files --error-unmatch "$$dir/.gitkeep" >/dev/null 2>&1; then \
			test "$$('/usr/bin/printf' '%s\n' "$$entries" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = '1'; \
		fi; \
	}; \
	{ \
		for dir in $(REQUIRED_MARKER_DIRS); do \
			check_leaf "$$dir"; \
			/usr/bin/printf '%s/.gitkeep\n' "$$dir"; \
		done; \
		i=1; \
		while test "$$i" -le 21; do \
			id="$$('/usr/bin/printf' 'T-%03d' "$$i")"; \
			check_leaf "Verification/runner-adapters/$$id"; \
			check_leaf "Verification/release-requirements/$$id"; \
			/usr/bin/printf 'Verification/runner-adapters/%s/.gitkeep\n' "$$id"; \
			/usr/bin/printf 'Verification/release-requirements/%s/.gitkeep\n' "$$id"; \
			i=$$((i + 1)); \
		done; \
	} | /usr/bin/sort >"$$allowed_markers"; \
	/usr/bin/git ls-files '*/.gitkeep' | /usr/bin/sort >"$$actual_markers"; \
	test -z "$$('/usr/bin/comm' -23 "$$actual_markers" "$$allowed_markers")"; \
	test ! -e Package.resolved; \
	test -z "$$('/usr/bin/git' ls-files .build build dist)"; \
	/usr/bin/printf 'pulsephone-structure.v1 state=passed\n'

verify-python-tooling:
	@set -eu; \
	interpreter=/usr/bin/python3; \
	manifest=Scripts/python-tooling-manifest.v1.json; \
	test -x "$$interpreter"; \
	test -f "$$manifest"; \
	test "$$('/usr/bin/plutil' -extract schemaVersion raw -o - "$$manifest")" = '1'; \
	test "$$('/usr/bin/plutil' -extract releaseIncluded raw -o - "$$manifest")" = 'false'; \
	test "$$('/usr/bin/plutil' -extract sourcePolicy raw -o - "$$manifest")" = 'host-provisioned-only-no-network-install'; \
	test "$$('/usr/bin/plutil' -extract profiles raw -o - "$$manifest")" = '1'; \
	test "$$('/usr/bin/plutil' -extract interpreter.path raw -o - "$$manifest")" = "$$interpreter"; \
	expected_version="$$('/usr/bin/plutil' -extract interpreter.major raw -o - "$$manifest").$$('/usr/bin/plutil' -extract interpreter.minor raw -o - "$$manifest")"; \
	actual_version="$$($$interpreter -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
	if test "$$actual_version" != "$$expected_version"; then \
		/usr/bin/printf 'unsupported Python tooling interpreter: expected=%s actual=%s\n' "$$expected_version" "$$actual_version" >&2; exit 2; \
	fi; \
	test "$$('/usr/bin/plutil' -extract profiles.0.profileID raw -o - "$$manifest")" = 'contract-tooling'; \
	test "$$('/usr/bin/plutil' -extract profiles.0.releaseIncluded raw -o - "$$manifest")" = 'false'; \
	test -d Scripts/lib/pulsephone_contracts; \
	for path in \
		Packaging/manifests/native-wheel.manifest.json \
		Packaging/manifests/python-dependency-inventory.json \
		Packaging/manifests/python-lock.input.txt \
		Packaging/manifests/python-lock.json \
		Packaging/manifests/python-lock.requirements.txt \
		Packaging/manifests/python-source-inventory.json \
		Packaging/manifests/wheelhouse.manifest.json \
		Packaging/licenses/python \
		Packaging/licenses/runtime \
		Packaging/scripts/build-python \
		Packaging/scripts/build-python-inventory \
		Packaging/scripts/verify-python-runtime; do \
		test ! -e "$$path"; \
	done; \
	if rg -n 'pythonRuntimeExcludedRelativePaths|Contents/Resources/Python|build-python|verify-python-runtime' \
		Scripts/package-app Packaging/manifests Packaging/licenses >/dev/null 2>&1; then \
		/usr/bin/printf 'Python release packaging input remains\n' >&2; exit 2; \
	fi; \
	/usr/bin/printf 'pulsephone-python-tooling.v1 state=passed interpreter=%s version=%s manifest=%s legacyDependencies=none releasePackagePython=absent\n' \
		"$$interpreter" "$$actual_version" "$$manifest"

build:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift build --configuration debug --build-tests

test:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --configuration debug

verify-standard-errors:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter StandardErrorRegistryTests

verify-wire-registry:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter WireRegistryTests

verify-generated-swift:
	@Scripts/generate-registries swift --verify
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter SwiftGenerationTests

verify-generated:
	@Scripts/generate-registries swift --verify
	@Scripts/generate-registries python --verify

verify-preparation-capture:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --configuration debug \
		--filter ArgumentPreflightDispatcherTests/testScreenshotPreservesPreparationRemediationDetailsWithoutArtifact
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --configuration debug \
		--filter ProductionRuntimeAssemblyTests/testRealSocketPreservesTypedFailureDetails
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --configuration debug \
		--filter ProductionRuntimeAssemblyTests/testModernCaptureCommandsStartPreparationBeforeCaptureAndRequireRetry

verify-evidence-policy-structural:
	@PYTHONDONTWRITEBYTECODE=1 Scripts/verify-contracts evidence-policy-structural
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter EvidencePolicyContractTests

verify-evidence-policy-release-complete:
	@PYTHONDONTWRITEBYTECODE=1 Scripts/evidence-tool contracts verify --profile evidence-policy-release-complete
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter ReleaseAggregatorTests

verify-contracts-bootstrap:
	@PYTHONDONTWRITEBYTECODE=1 Scripts/verify-contracts bootstrap
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter EvidenceContract

verify-contracts-current:
	@PYTHONDONTWRITEBYTECODE=1 Scripts/verify-contracts current
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test \
		--filter 'CurrentIdentityTests|EvidenceContract'

verify-command-catalog-partial:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test --filter CatalogRowsTests

verify-command-matrix:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test \
		--filter 'CommandMatrixCoverageTests|NegativeExposureTests|GUIExposureTests'

verify-developer-image-catalog-partial:
	@developer_dir="$$('/usr/bin/xcode-select' -p)"; \
	DEVELOPER_DIR="$$developer_dir" /usr/bin/xcrun swift test \
		--filter PulsePhoneDeveloperImageCatalogTests

test-python:
	@case '$(PYTHON_TEST)' in \
		registry_parity) \
			PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Scripts/lib \
				/usr/bin/python3 -m unittest discover \
				-s Tests/Unit/PythonRegistryTests -p 'test_*.py' ;; \
		tooling_python) \
			PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Scripts/lib \
				/usr/bin/python3 -m unittest discover \
				-s Tests/Integration/ToolingPythonTests -p 'test_*.py' ;; \
		*) /usr/bin/printf 'unsupported PYTHON_TEST: %s\n' '$(PYTHON_TEST)' >&2; exit 2 ;; \
	esac

check:
	@/usr/bin/make --no-print-directory doctor
	@/usr/bin/make --no-print-directory verify-structure
	@/usr/bin/make --no-print-directory verify-python-tooling
	@/usr/bin/make --no-print-directory verify-go-dependencies
	@/usr/bin/make --no-print-directory verify-generated-go
	@/usr/bin/make --no-print-directory test-go
	@/usr/bin/make --no-print-directory build-go
	@/usr/bin/make --no-print-directory build
	@/usr/bin/make --no-print-directory test
	@/usr/bin/make --no-print-directory verify-generated
	@/usr/bin/make --no-print-directory test-python PYTHON_TEST=registry_parity
	@/usr/bin/make --no-print-directory verify-contracts-current

verify-m0-gate: GATE_OWNER = M0-900
verify-m1-gate: GATE_OWNER = M1-900
verify-m2-gate: GATE_OWNER = M2-900
verify-negative-removal: GATE_OWNER = M3-010A
verify-threshold-freeze: GATE_OWNER = M3-014
verify-final-release-evidence: GATE_OWNER = M3-017
verify-m3-release-gate: GATE_OWNER = M3-900

verify-m0-gate verify-m1-gate verify-m2-gate verify-negative-removal verify-threshold-freeze verify-final-release-evidence verify-m3-release-gate:
	@if test ! -x Scripts/implementation-gate; then \
		/usr/bin/printf 'pulsephone-gate-stub.v1 target=%s owner=%s state=not-ready\n' '$@' '$(GATE_OWNER)'; \
		exit 1; \
	fi
	@set -eu; \
	for pair in $(foreach variable,$(GATE_VARIABLES),'$(variable)=$(origin $(variable))'); do \
		origin="$${pair#*=}"; \
		case "$$origin" in undefined|'command line') ;; *) /usr/bin/printf 'invalid Make variable origin: %s\n' "$$pair" >&2; exit 2 ;; esac; \
	done
	@exec Scripts/implementation-gate --target '$@' \
		$(if $(filter command line,$(origin GATE_SOURCE_POLICY_ID)),--make-variable 'GATE_SOURCE_POLICY_ID=$(value GATE_SOURCE_POLICY_ID)') \
		$(if $(filter command line,$(origin GATE_WRITE_GRANT)),--make-variable 'GATE_WRITE_GRANT=$(value GATE_WRITE_GRANT)') \
		$(if $(filter command line,$(origin GATE_NEGATIVE_REMOVAL_PLAN_RECORD)),--make-variable 'GATE_NEGATIVE_REMOVAL_PLAN_RECORD=$(value GATE_NEGATIVE_REMOVAL_PLAN_RECORD)') \
		$(if $(filter command line,$(origin GATE_THRESHOLD_FREEZE_RECORD)),--make-variable 'GATE_THRESHOLD_FREEZE_RECORD=$(value GATE_THRESHOLD_FREEZE_RECORD)') \
		$(if $(filter command line,$(origin GATE_THRESHOLD_FREEZE_HOLD)),--make-variable 'GATE_THRESHOLD_FREEZE_HOLD=$(value GATE_THRESHOLD_FREEZE_HOLD)')
