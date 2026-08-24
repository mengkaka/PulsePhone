#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import time


def response(request, result=None, ok=True, request_id=None):
    value = {
        "ok": ok,
        "operation": request["operation"],
        "requestID": request["requestID"] if request_id is None else request_id,
        "schemaVersion": 1,
    }
    if ok:
        value["result"] = result
    else:
        value["error"] = {"code": "probeUnavailable"}
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def enumerate_result():
    return {
        "devices": [
            {
                "deviceID": 17,
                "rawTransportUDID": "00008030-001C2D",
                "transport": "usb",
            }
        ],
        "observedAtMonotonicNs": 123456,
    }


def probe_result():
    return {
        "condition": {"connected": True, "locked": False, "trusted": True},
        "facts": {
            "buildVersion": "23F79",
            "deviceClass": "iPhone",
            "deviceName": "Fixture iPhone",
            "productType": "iPhone14,7",
            "productVersion": "26.5",
            "uniqueDeviceID": "00008030-001C2D",
        },
        "provenance": {
            "autopair": False,
            "mode": "directHelperFacts",
            "queriedKeys": [
                "BuildVersion",
                "DeviceClass",
                "DeviceName",
                "ProductType",
                "ProductVersion",
                "UniqueDeviceID",
            ],
        },
    }


def main():
    scenario = sys.argv[1]
    marker = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    request = json.loads(sys.stdin.buffer.readline())
    result = enumerate_result() if request["operation"] == "enumerate" else probe_result()

    if scenario == "malformed":
        sys.stdout.write("not-json\n")
    elif scenario == "second-line":
        sys.stdout.write(response(request, result) + "\n{}\n")
    elif scenario == "request-mismatch":
        sys.stdout.write(
            response(
                request,
                result,
                request_id="00000000-0000-0000-0000-000000000099",
            )
            + "\n"
        )
    elif scenario == "nonzero":
        sys.stdout.write(response(request, result) + "\n")
        sys.stdout.flush()
        return 3
    elif scenario == "timeout-group":
        subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import pathlib,sys,time;time.sleep(0.35);pathlib.Path(sys.argv[1]).write_text('leaked')",
                str(marker),
            ]
        )
        time.sleep(5)
    elif scenario == "valid-waitpid":
        sys.stdout.write(response(request, result) + "\n")
        sys.stdout.flush()
        time.sleep(0.05)
        marker.write_text("exited", encoding="utf-8")
    else:
        sys.stdout.write(response(request, result) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
