---
name: pulsephone
description: >-
  Control and inspect a USB-connected iPhone with the PulsePhone macOS CLI. Use for iPhone
  gestures, typing, buttons, app operations, screenshots, live view, element inspection, or
  device and Runtime diagnostics.
---

# PulsePhone iPhone Automation

Control a physical iPhone with the globally installed `PulsePhone` CLI.

## Start

Before the first device operation in a task, run:

```bash
PulsePhone version --json
```

Require a successful `product.version` envelope with non-empty version and build. If it is missing
or invalid, stop device work and report that the PulsePhone CLI must be installed or repaired. Do
not guess an app path, edit `PATH`, or invoke a bundle-relative executable.

Discover and select the target once:

```bash
PulsePhone devices --json
```

Use only an eligible USB iPhone. If multiple devices are eligible, use the user's stated target or
ask which one to use. Pass its canonical `--udid` to every subsequent device command.

Use `PulsePhone --help`, `PulsePhone <command> --help`, or `PulsePhone commands --json` when an
option or compatibility contract is uncertain. Help is local and does not touch the device.

## Observe And Control

Use `--json` for agent work except Help and the default JSON `element snapshot`. Verify every
visible mutation with a fresh observation; a successful command alone is not proof of the
user-visible result.

```text
observe current viewport -> choose target -> act -> observe again
```

Use the least invasive observation that answers the task:

```bash
PulsePhone element snapshot --udid <UDID>
PulsePhone screenshot --output /absolute/capture.png --udid <UDID> --json
PulsePhone element snapshot --format both --output /absolute/elements.png --udid <UDID>
PulsePhone live --udid <UDID> --json
```

`element snapshot` covers only the current viewport. For a selected element, use
`center.normalized.x` and `center.normalized.y` directly; coordinates for `tap`, `swipe`, and
`drag` are normalized `0...1`. When a target is absent, make one intentional swipe, observe again,
then reassess. Do not infer persistent element IDs, off-screen elements, or a successful tap from
command success alone.

```bash
PulsePhone tap --x 0.5 --y 0.5 --udid <UDID> --json
PulsePhone swipe --from 0.5,0.8 --to 0.5,0.2 --duration 300 --udid <UDID> --json
PulsePhone drag --from 0.5,0.8 --to 0.5,0.2 --duration 500 --udid <UDID> --json
PulsePhone rotate --direction left --udid <UDID> --json
```

For navigation, prefer a visible Back, Close, Cancel, or return control from a fresh snapshot.
Use `PulsePhone button home` to leave an unknown state; do not guess screen-edge coordinates.

Tap a visible text field before editing it:

```bash
PulsePhone type --text "hello" --udid <UDID> --json
PulsePhone text clear --udid <UDID> --json
PulsePhone text key --key return --udid <UDID> --json
PulsePhone text cursor --move word-left --count 2 --select --udid <UDID> --json
```

Re-observe after text input. If focus is wrong, observe and retarget instead of repeating input.

## Apps, Files, And Diagnostics

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

Install and uninstall change device contents: perform them only on explicit user request, require
an absolute IPA path, and verify with `apps` when useful. Screenshot and annotation output paths
must be absolute; add `--force` only when replacing that existing output is intended.

Start and stop trace or diagnostics recordings as matched pairs. Clear logs only when the user
asked to do so. Use `live --select-source` only when the user wants to replace or choose the Mac
capture source.

## Interpret And Recover

Read `error.code`, `error.details`, target identity, and `metadata.runtimeMayContinue` from an
unsuccessful envelope. Prefer those fields to human prose.

- For invalid arguments or paths, correct the named option with command help; do not investigate
  connectivity or repeat unchanged input.
- For `noDeviceConnected`, `deviceNotFound`, or `deviceDisconnected`, refresh `devices --json` and
  use `status --udid <UDID> --json` when a target remains selected.
- Do not run `device prepare` as routine preflight. Run it only when the user explicitly requests
  preparation or when `error.code` is `capabilityPreparing` and
  `error.details.remediation` is `runDevicePrepare`:

  ```bash
  PulsePhone device prepare --udid <UDID> --json
  ```

  Wait for its terminal envelope, then retry the original command once. That remediation means the
  original command was not accepted or executed.
- For other Developer Support, trust, lock, compatibility, Runtime, or transport errors, report
  `error.code` and relevant `error.details`. Do not relabel them as disconnection or keep retrying
  preparation.
- For `outcomeUnknown` or `guiLaunchOutcomeUnknown`, re-observe before any retry; never
  automatically repeat a mutating command.

## Finish

Confirm the selected iPhone and app are in the expected state, verify the final visible mutation,
and report any error code, limitation, or unverified outcome.
