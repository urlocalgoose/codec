#!/usr/bin/env python3
"""Build/install Codec Test, with a separate app identity and persistent simulator.

No archive, export, upload, production install, or implicit device selection.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios/CodecMobile"
PROJECT = IOS / "Codec.xcodeproj"
STATE = ROOT / ".codec-dev/ios"
BUNDLE = "sh.codie.codec.mobile.test"
SIM_NAME = "Codec Local Test"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=check)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def check_configuration() -> None:
    project = json.loads(run("plutil", "-convert", "json", "-o", "-", str(PROJECT / "project.pbxproj")).stdout)
    objects = project["objects"]
    configs = objects[objects["100000000000000000000401"]["buildConfigurationList"]]["buildConfigurations"]
    settings = {objects[key]["name"]: objects[key]["buildSettings"] for key in configs}
    for name in ("Debug", "Release"):
        require(settings[name]["PRODUCT_BUNDLE_IDENTIFIER"] == "sh.codie.codec.mobile", f"Unexpected {name} app identity")
        require(settings[name]["INFOPLIST_FILE"] == "App/Info.plist", f"Unexpected {name} Info.plist")
        require("LOCAL_TEST" not in settings[name].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""), f"Test flag leaked into {name}")
    project_configs = objects[project["rootObject"]]["buildConfigurationList"]
    for key in objects[project_configs]["buildConfigurations"]:
        config = objects[key]
        flags = config["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        require(("LOCAL_TEST" in flags) == (config["name"] == "LocalTest"), "LOCAL_TEST must apply only to the test configuration")
        require(not config["buildSettings"].get("CODE_SIGN_ENTITLEMENTS"), "Review new project-level shared-storage entitlements")
    local = settings["LocalTest"]
    require(local["PRODUCT_BUNDLE_IDENTIFIER"] == BUNDLE, "Codec Test must have its own bundle identifier")
    require(local["INFOPLIST_FILE"] == "App/LocalTest-Info.plist", "Codec Test must use its own Info.plist")
    require(local["SKIP_INSTALL"] == "YES", "Codec Test must be excluded from install/archive products")
    require(not local.get("CODE_SIGN_ENTITLEMENTS"), "Review any added shared storage entitlement")
    normal = plistlib.loads((IOS / "App/Info.plist").read_bytes())
    test = plistlib.loads((IOS / "App/LocalTest-Info.plist").read_bytes())
    require(normal["CFBundleDisplayName"] == "Codec", "Unexpected production display name")
    require(test["CFBundleDisplayName"] == "Codec Test", "Test install must be visibly named Codec Test")
    require(normal["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["codec"], "Unexpected production Aux URL scheme")
    require(test["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["codec-test"], "Test install must not register production Aux URLs")
    for key in ("CFBundleDisplayName", "CFBundleURLTypes"):
        normal.pop(key)
        test.pop(key)
    require(normal == test, "Keep LocalTest-Info.plist in sync with production capabilities")
    scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/Codec Test.xcscheme")
    for action in ("TestAction", "LaunchAction", "ProfileAction", "AnalyzeAction", "ArchiveAction"):
        require(scheme.find(action).get("buildConfiguration") == "LocalTest", f"Test scheme {action} must use LocalTest")
    require(scheme.find("BuildAction/BuildActionEntries/BuildActionEntry").get("buildForArchiving") == "NO", "Codec Test must not be archived")


def simulator() -> str:
    listing = json.loads(run("xcrun", "simctl", "list", "-j").stdout)
    eligible = [runtime for runtime in listing["runtimes"] if runtime.get("isAvailable") and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if not eligible:
        raise RuntimeError("Install an iOS simulator runtime in Xcode first.")
    eligible.sort(key=lambda runtime: tuple(int(part) for part in runtime["version"].split(".")), reverse=True)
    # Reuse this dedicated simulator across runs, never the user's booted phone preview.
    for runtime in eligible:
        matches = [device for device in listing["devices"].get(runtime["identifier"], []) if device.get("isAvailable") and device["name"] == SIM_NAME]
        if len(matches) > 1:
            raise RuntimeError("Multiple Codec Local Test simulators exist; rename the extra in Xcode.")
        if matches:
            return matches[0]["udid"]
    runtime = eligible[0]
    major = int(runtime["version"].split(".")[0])
    model = "iPhone-17" if major >= 26 else "iPhone-15"
    return run("xcrun", "simctl", "create", SIM_NAME, f"com.apple.CoreSimulator.SimDeviceType.{model}", runtime["identifier"]).stdout.strip()


def build(args: argparse.Namespace, destination: str, sdk: str, operation: str = "build") -> Path:
    derived = STATE / "DerivedData"
    log = STATE / f"{args.command}.log"
    command = ["xcodebuild", "-project", str(PROJECT), "-scheme", "Codec Test", "-configuration", "LocalTest", "-destination", destination,
               "-derivedDataPath", str(derived), operation]
    if sdk == "iphonesimulator":
        # Simulator Keychain requires an app signature. Ad-hoc signing stays
        # local and needs no Apple account or device provisioning profile.
        command.extend(["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"])
    else:
        command.append(f"DEVELOPMENT_TEAM={args.team}")
        if args.allow_provisioning:
            command.append("-allowProvisioningUpdates")
    print(f"Building Codec Test ({sdk}); log: {log}", flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Xcode {operation} failed. Read {log}; everyday Codec was not installed or changed.")
    app = derived / f"Build/Products/LocalTest-{sdk}/Codec.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == BUNDLE, "Refusing to install a production app identity")
    require(info["CFBundleDisplayName"] == "Codec Test", "Built app must be visibly named Codec Test")
    require(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["codec-test"], "Built test app must not register production Aux URLs")
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="Check isolation and production/test plist parity; no build")
    sim = commands.add_parser("simulator", help="Build and install on the persistent dedicated simulator")
    sim.add_argument("--build-only", action="store_true", help="Build without booting or installing")
    commands.add_parser("test", help="Run native regressions on the dedicated simulator using Codec Test")
    device = commands.add_parser("device", help="Install alongside everyday Codec on an explicitly chosen phone")
    device.add_argument("--id", required=True, help="Explicit connected device UDID")
    device.add_argument("--team", required=True, help="Apple development signing team ID")
    device.add_argument("--allow-provisioning", action="store_true", help="Allow Xcode to register/provision this separate development app (never uploads a build)")
    device.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    check_configuration()
    if args.command == "check":
        print("Codec Test identity, URL scheme, archive exclusion, and production plist parity passed.")
        return
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True)
    if args.command == "device":
        if not args.id or not args.team.isalnum():
            raise RuntimeError("Provide a device UDID and valid development team ID.")
        app = build(args, f"platform=iOS,id={args.id}", "iphoneos")
        if not args.build_only:
            run("xcrun", "devicectl", "device", "install", "app", "--device", args.id, str(app))
            run("xcrun", "devicectl", "device", "process", "launch", "--device", args.id, BUNDLE)
        print(f"Codec Test {'built' if args.build_only else 'installed'}: {BUNDLE}")
        print("Connect using the lab's private Tailscale HTTPS address and local server A or B token (local:share).")
        return
    if getattr(args, "build_only", False):
        app = build(args, "generic/platform=iOS Simulator", "iphonesimulator")
        print(f"Built: {app}")
        return
    udid = simulator()
    run("xcrun", "simctl", "boot", udid, check=False)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    app = build(args, f"platform=iOS Simulator,id={udid}", "iphonesimulator", "test" if args.command == "test" else "build")
    if args.command == "test":
        print(f"Native tests passed. Log: {STATE / 'test.log'}")
        return
    run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    run("xcrun", "simctl", "install", udid, str(app))
    run("xcrun", "simctl", "launch", udid, BUNDLE)
    run("open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid)
    (STATE / "simulator.json").write_text(json.dumps({"udid": udid, "name": SIM_NAME, "bundle_id": BUNDLE}, indent=2) + "\n")
    print(f"Codec Test is running in {SIM_NAME}. Everyday Codec is unchanged.")
    print("First connection: http://127.0.0.1:8791 (A) or :8792 (B). Copy its token with local-dev.py auth a/b.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Codec Test: {error}", file=sys.stderr)
        sys.exit(1)
