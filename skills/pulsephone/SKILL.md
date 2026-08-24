---
name: pulsephone
description: >-
  Control and inspect a physical USB-connected iPhone with the PulsePhone macOS CLI. Use when
  asked to tap, swipe, drag, rotate, type text, send keyboard keys, press device buttons, launch,
  install, list, or uninstall iPhone apps, open the live device view, take screenshots, analyze
  visible current-viewport elements and coordinates, inspect device or Runtime state, prepare
  device support, or collect PulsePhone traces, diagnostics, and logs.
---

# PulsePhone iPhone Automation

Control a real iPhone over USB with the globally installed `PulsePhone` CLI.

## Verify PulsePhone

Before the first device operation in a task, run:

```bash
PulsePhone version --json
```

Require a successful `product.version` envelope with non-empty version and build. If the command
is missing or invalid, stop device work and ask the user to reinstall this skill from a complete
PulsePhone.app with `skill install`. Do not guess an app path, edit shell profiles or `PATH`,
perform an app installation, or use a bundle-relative executable.

## Start Every Device Task

Use machine output for agent work:

```bash
PulsePhone devices --json
```

Select only an eligible USB iPhone. When more than one exists, identify the intended device from
the user's request or ask which one to use. Once selected, pass its canonical `--udid` to every
device command so a connection change cannot redirect later actions.

Before every device-scoped operation, including `status`, run one explicit preparation for the
selected target:

```bash
PulsePhone device prepare --udid <UDID> --json
```

Wait for its terminal envelope before continuing. An `alreadyReady` result is inexpensive. Do not
replace this with a speculative normal command: when Developer Support is not ready, ordinary
DDI-dependent commands start or join preparation but intentionally return a typed remediation
instead of waiting or replaying the requested action. Pairing, trust, lock state, OS compatibility,
or unavailable Developer Support must be reported from the command result rather than guessed.

Use `PulsePhone --help`, `PulsePhone <command> --help`, or `PulsePhone commands --json` whenever
the exact current option or compatibility contract matters. Help is local and does not touch the
device or start Runtime.

## Operate Deliberately

PulsePhone drives a physical device. A successful request means the command reached its defined
terminal state; still verify user-visible mutations from a fresh observation. If the same action
with the same parameters has no expected effect twice, stop repeating it, re-observe the screen,
and change strategy.

Prefer this loop:

```text
observe current viewport -> choose normalized center -> act -> observe again
```

Use one of these observations:

- `PulsePhone element snapshot --udid <UDID>` for structured visible elements and coordinates.
- `PulsePhone screenshot --output <ABSOLUTE_PATH> --udid <UDID> --json` for an unannotated PNG.
- `PulsePhone element snapshot --format both --output <ABSOLUTE_PATH> --udid <UDID>` for JSON
  plus an annotation PNG from the same capture.
- `PulsePhone live --udid <UDID> --json` when the user needs the interactive Mac live window.

Never infer that a tap worked only because the command returned `ok: true`. Re-snapshot after a
page transition, launch, rotation, or input that should visibly change state.

## Find and Tap Visible Elements

`element snapshot` is passive current-viewport visual analysis. It does not install WebDriver or
an XCTest Runner, move Accessibility focus, synthesize input, or scroll to off-screen content.
It can return controls and text visible in the captured viewport; it is not an accessibility
hierarchy and does not provide persistent element IDs.

Run:

```bash
PulsePhone element snapshot --udid <UDID>
```

The default output is JSON. For a selected element, use its `center.normalized.x` and
`center.normalized.y` directly:

```bash
PulsePhone tap --x <NORMALIZED_X> --y <NORMALIZED_Y> --udid <UDID> --json
```

Do not compute a center from a pixel box when `center.normalized` exists. Normalized touch
coordinates are in the inclusive range `0...1`, matching `tap`, `drag`, and `swipe`. Pixel and
logical-point frames are for image inspection and reporting, not direct touch input.

When duplicate labels exist, disambiguate using element kind, confidence, frame, surrounding
text, and screen position. Prefer control candidates over text-only regions for tapping. If the
target is not in the snapshot, perform one intentional swipe, capture a new snapshot, and search
again; do not assume `element snapshot` will reveal off-screen content.

Annotation modes:

```bash
PulsePhone element snapshot --format annotated --output /absolute/elements.png --udid <UDID>
PulsePhone element snapshot --format both --output /absolute/elements.png --udid <UDID>
```

Use `--force` only when replacing an existing annotation PNG is intended. It affects atomic
output-file replacement, not analyzer selection, capture freshness, confidence, or correction.
Do not combine global `--json` with `--format annotated`; use default `json` or `both` when JSON
is required.

## Touch, Gestures, and Orientation

All touch points are normalized:

```bash
PulsePhone tap --x 0.5 --y 0.5 --udid <UDID> --json
PulsePhone swipe --from 0.5,0.8 --to 0.5,0.2 --duration 300 --udid <UDID> --json
PulsePhone drag --from 0.5,0.8 --to 0.5,0.2 --duration 500 --udid <UDID> --json
PulsePhone rotate --direction left --udid <UDID> --json
```

Use `swipe` for a quick gesture such as page scrolling and `drag` for a sustained linear move.
Durations are milliseconds. Rotation directions are `left` and `right`, each one relative
quarter-turn. These controls require iOS 17+.

For navigation, first tap a visible Back, Close, Cancel, or return control from a fresh element
snapshot. PulsePhone has no semantic `back` command. To leave an unknown state, use a visible
control or `PulsePhone button home`; do not guess a screen-edge coordinate.

## Type and Edit Text

Tap the intended visible text field first, then use:

```bash
PulsePhone type --text "hello" --udid <UDID> --json
PulsePhone text clear --udid <UDID> --json
PulsePhone text key --key return --udid <UDID> --json
PulsePhone text cursor --move word-left --count 2 --select --udid <UDID> --json
PulsePhone text input-source next --udid <UDID> --json
```

`type` sends UTF-8 text to the focused device field; it does not find or focus a field. `text
clear` clears the focused editable field. `text key` supports letters, digits, editing,
punctuation, navigation keys, and optional `--command`, `--control`, `--option`, `--shift`, and
`--repeat`. Read `PulsePhone text key --help` for the current key allowlist. Text controls require
iOS 17+.

After typing or editing, re-snapshot and verify the visible value or resulting state. If focus is
wrong, do not repeat the text command; re-observe and tap the correct field.

## Apps and Device Buttons

Use:

```bash
PulsePhone apps --udid <UDID> --json
PulsePhone launch --bundle-id com.example.App --udid <UDID> --json
PulsePhone install --path /absolute/App.ipa --udid <UDID> --json
PulsePhone uninstall --bundle-id com.example.App --udid <UDID> --json

PulsePhone button home --udid <UDID> --json
PulsePhone button app-switcher --udid <UDID> --json
PulsePhone button lock --udid <UDID> --json
PulsePhone button volume-up --udid <UDID> --json
PulsePhone button volume-down --udid <UDID> --json
PulsePhone button mute --udid <UDID> --json
```

`install` and `uninstall` change device contents. Execute them only when the user requested that
change, use an absolute `.ipa` path, and verify the result with `apps` when useful. App listing,
install, and uninstall support iOS 14+; launch is available on iOS 17+ and conditionally on iOS
14-16 with prepared classic Developer Support. Device buttons require iOS 17+.

## Screenshots and Live View

Write screenshots only to an absolute normalized path:

```bash
PulsePhone screenshot --output /absolute/capture.png --udid <UDID> --json
```

If the path already exists and replacement is intended, add `--force`. `--force` only permits an
atomic replacement of an existing regular output file. It does not force a new Runtime, bypass
capability checks, or change the screenshot source.

Use `PulsePhone live --select-source --udid <UDID> --json` only when the user needs to replace or
choose the Mac capture source. A normal `live` call reuses a valid saved source mapping when
available.

## Diagnostics and Runtime

Use these commands for explicit diagnostics requests:

```bash
PulsePhone trace start --udid <UDID> --json
PulsePhone trace stop --udid <UDID> --json
PulsePhone diagnostics start --udid <UDID> --json
PulsePhone diagnostics stop --udid <UDID> --json
PulsePhone runtime status --udid <UDID> --json
PulsePhone stop --udid <UDID> --json
PulsePhone logs clear --udid <UDID> --json
PulsePhone logs clear --all --json
PulsePhone logs prune --json
```

Start and stop recordings as matched pairs. Do not clear logs unless the user requested it.
`stop` stops an idle target Runtime; it is not a force-kill command. Use global `runtime status`
without `--udid` only to inspect currently discovered Runtime states.

## Interpret Results

Except for Help and the default machine-oriented element command, add global `--json` for agent
work. Product Actions emit one envelope:

```json
{"commandID":"...","ok":true,"result":{},"schemaVersion":1,"target":{}}
```

On failure, inspect `error.code`, `error.message`, optional `error.details`, target identity, and
`metadata.runtimeMayContinue`. Prefer the typed code and details over human prose. Do not treat
`runtimeMayContinue: true` as success; it only indicates that the Runtime may remain usable after
the failed action.

Classify before recovering:

- `invalidArgument`, `invalidCoordinate`, `invalidDuration`, `invalidUDID`, `invalidOutputPath`,
  `invalidIPAPath`, `argumentTooLarge`: fix the named option using its reason/suggestion and
  command help. Do not inspect connectivity or repeat an unchanged command.
- `noDeviceConnected`, `deviceNotFound`, `deviceDisconnected`: refresh `devices --json` and,
  for a selected UDID, `status --udid <UDID> --json`. Say the device is offline only when the
  selected UDID is absent or the status explicitly confirms disconnection.
- `developerSupportUnavailable`, `developerModeRequired`, `developerServicesUnavailable`,
  `capabilityUnavailable`, `preparationTimeout`: the USB device may still be connected. Inspect
  status and run `device prepare` only when the reported capability/support error calls for it.
- `runtimeNotRunning`, `runtimeFailed`, `runtimeStartupTimeout`, `incompatibleRuntime`,
  `transportFailure`: inspect `runtime status` and device status; do not translate these codes
  into device disconnection without discovery evidence.
- `queueFull`, `resourceBusy`, `capabilityPreparing`, `runtimeStopping`, `liveAlreadyOpen`: wait,
  stop the conflicting owner when requested, or change strategy; this is not a connection error.
- `outcomeUnknown`, `guiLaunchOutcomeUnknown`: never automatically repeat a mutating command;
  re-observe first. A read-only observation may be retried once after a retryable service/runtime
  failure.

For an unsuccessful command, report the exact `error.code`, the blocking reason, what remains
unverified, and one actionable next step. Do not report `truncated:false`, successful discovery
checks, internal retries, or Runtime details unless they change the next action. Never claim
"device disconnected" without explicit connection evidence.

## Finish the Task

Before reporting completion:

1. Confirm the intended iPhone and app are in the expected state.
2. Verify the last visible mutation with a fresh element snapshot or screenshot.
3. Confirm requested files exist at their exact absolute paths.
4. Stop only recordings or Runtime sessions that the task explicitly requires you to stop.
5. Report typed CLI failures and compatibility limits instead of claiming an unobserved result.
