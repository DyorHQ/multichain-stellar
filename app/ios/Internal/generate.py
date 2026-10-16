#!/usr/bin/env python3
"""Generates DyorHQInternal.xcodeproj: the DyorHQ app with DyorHQ Lite (Stellar), for the internal TestFlight group.

It is a separate project on purpose. Xcode resolves every package a project references, whichever target links it,
and the App Store app is built from the public DyorHQ/IOS-app repository, which doesn't have the Lite packages, so
the App Store project (project.yml → DyorHQ.xcodeproj) must never reference them. A compile flag can't unlink a
package either.

project.yml stays the single source of truth: this script takes XcodeGen's resolved dump of it, adds Lite to the
DyorHQ target (the two packages, STELLAR_LITE, the Lite API URL and media base, its own Info.plist), adds the hosted
unit tests of the app's Stellar glue (DyorHQInternalTests, Internal/Tests), writes project-internal.json (git-ignored)
and generates DyorHQInternal.xcodeproj next to DyorHQ.xcodeproj, so $(SRCROOT) means the same in both.

Info.plist is the Release one. Debug builds read Info-Debug.plist, written here from it with one key more:
NSAllowsLocalNetworking, for the local Lite API on 127.0.0.1 (an Info.plist can't vary a Boolean by configuration).

This app lives in the private DyorHQ/multichain-stellar repository, as app/ (a copy of the public app, updated with
git subtree pull --prefix=app), next to the Lite packages in ios/Packages. From app/ios/:
    python3 Internal/generate.py                      # from project.yml
    python3 Internal/generate.py --spec other.yml     # e.g. a local spec without the secrets config
Run it again after adding or removing the testnet-qa pins (PinnedContracts+TestnetQA.swift): Debug builds can select
them only when they were there at generation (STELLAR_QA_PINS, LITE_PINNED=testnet-qa).
"""
import argparse
import json
import os
import plistlib
import subprocess

IOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INFO = "Internal/Info.plist"
DEBUG_INFO = "Internal/Info-Debug.plist"
TESTS = "DyorHQInternalTests"
# The testnet-qa deployment's pins, which backend/scripts/gen-pinned.ts writes only where the owner allows that
# deployment (docs/DESIGN-stellar-parity.md §6.16).
QA_PINS = "StellarKit/Sources/StellarCore/Network/PinnedContracts+TestnetQA.swift"
# Where DyorHQ's Stellar media lives (docs/DESIGN-stellar-parity.md §3.8): pinned per configuration, never taken from
# the server. Release reads the project's lite-media bucket and its image renderer; Debug the local stack's stand-in,
# originals only.
RELEASE_MEDIA = "https:/$()/fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/"
RELEASE_RENDER = "https:/$()/fmnjqrguvopusfufmirs.supabase.co/storage/v1/render/image/public/lite-media/"
DEBUG_MEDIA = "http:/$()/127.0.0.1:8000/lite/v1/local-media/lite-media/"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spec", default="project.yml", help="the app's XcodeGen spec, relative to ios/")
    ap.add_argument("--lite", default="../../ios/Packages",
                    help="multichain-stellar's ios/Packages, relative to app/ios/")
    args = ap.parse_args()

    for package in ("StellarKit", "DyorLite"):
        if not os.path.isfile(os.path.join(IOS, args.lite, package, "Package.swift")):
            raise SystemExit(f"{package} not found under {args.lite} (relative to app/ios/): run this from the multichain-stellar repository")
    qa_pins = os.path.isfile(os.path.join(IOS, args.lite, QA_PINS))

    # --no-env: keep the spec literal; build settings like $(inherited) are not environment variables.
    dump = subprocess.run(["xcodegen", "dump", "--spec", args.spec, "--type", "json", "--no-env"],
                          cwd=IOS, capture_output=True, text=True, check=True).stdout
    spec = json.loads(dump)
    spec.pop("include", None)  # already resolved into the dump; keeping it would merge the included spec twice
    spec["name"] = "DyorHQInternal"
    spec.setdefault("packages", {}).update({
        "StellarKit": {"path": f"{args.lite}/StellarKit"},
        "DyorLite": {"path": f"{args.lite}/DyorLite"},
    })

    target = spec["targets"]["DyorHQ"]
    target["dependencies"] += [{"package": "DyorLite"}, {"package": "StellarKit", "product": "StellarKit"}]
    sources = target["sources"]
    if len(sources) != 1 or sources[0].get("path") != "DyorHQ":
        raise SystemExit(f"unexpected sources in {args.spec}: {sources}; update Internal/generate.py")
    # The App Store Info.plist is a plain file to this target: keep it out of the bundle's resources.
    sources[0].setdefault("excludes", []).append("Info.plist")
    # Resources only this app ships, e.g. logo-XLM.png (Stellar's official mark, as MarketLogo's `logo-<symbol>`).
    sources.append({"path": "Internal/Resources"})

    info = target["info"]
    info["path"] = INFO
    info["properties"].update({
        # The Lite API: the local stack in Debug (docs/RUNBOOK-testnet.md in multichain-stellar), the DyorHQ project's
        # lite function in Release. A public URL, no key.
        "LITE_API_URL": "$(LITE_API_URL)",
        # The only origin Stellar images and videos load from (`LiteGate.mediaBase`, `LiteMediaPolicy`), and the
        # storage's image renderer for it (Release only).
        "LITE_MEDIA_BASE": "$(LITE_MEDIA_BASE)",
        "LITE_RENDER_BASE": "$(LITE_RENDER_BASE)",
        # Debug only: the contracts this build pins, `testnet` (the default) or `testnet-qa` where its pins exist, from
        # LITE_PINNED (`xcodebuild … LITE_PINNED=testnet-qa`). Empty in Release, and Release code ignores it anyway.
        "LitePinned": "$(DYOR_DEBUG_LITE_PINNED)",
        # Debug only: shows the network switch without the `stellarLite` remote flag (empty in Release, and Release
        # code ignores it anyway).
        "LiteDebugForceOn": "$(DYOR_DEBUG_LITE_FORCE_ON)",
    })

    conditions = "$(inherited) STELLAR_LITE"
    debug_conditions = conditions + (" STELLAR_QA_PINS" if qa_pins else "")
    settings = target.setdefault("settings", {})
    settings.setdefault("base", {})["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = conditions
    configs = settings.setdefault("configs", {})
    configs.setdefault("Debug", {}).update({
        "LITE_API_URL": "http:/$()/127.0.0.1:8000/lite",
        "LITE_MEDIA_BASE": DEBUG_MEDIA,
        "LITE_RENDER_BASE": "",
        "DYOR_DEBUG_LITE_PINNED": "$(LITE_PINNED)",
        "DYOR_DEBUG_LITE_FORCE_ON": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": debug_conditions,
        # Info.plist plus NSAllowsLocalNetworking: the simulator reaches the local Lite API over plain HTTP on 127.0.0.1.
        "INFOPLIST_FILE": DEBUG_INFO,
    })
    configs.setdefault("Release", {}).update({
        "LITE_API_URL": "https:/$()/fmnjqrguvopusfufmirs.supabase.co/functions/v1/lite",
        "LITE_MEDIA_BASE": RELEASE_MEDIA,
        "LITE_RENDER_BASE": RELEASE_RENDER,
        "DYOR_DEBUG_LITE_PINNED": "",
        "DYOR_DEBUG_LITE_FORCE_ON": "",
    })

    # The app's Stellar glue, tested inside the app it is part of (docs/DESIGN-stellar-parity.md §12.2): one hosted
    # unit-test bundle, compiled with the app's conditions, run by the DyorHQ scheme's Test action.
    spec["targets"][TESTS] = {
        "type": "bundle.unit-test",
        "platform": "iOS",
        "sources": [{"path": "Internal/Tests"}],
        "dependencies": [{"target": "DyorHQ"}],
        "settings": {
            "base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "fun.dyorhq.app.internal-tests",
                "GENERATE_INFOPLIST_FILE": True,
                "TARGETED_DEVICE_FAMILY": "1",
                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/DyorHQ.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/DyorHQ",
                "BUNDLE_LOADER": "$(TEST_HOST)",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": conditions,
            },
            "configs": {"Debug": {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": debug_conditions}},
        },
    }
    scheme = target.setdefault("scheme", {})
    scheme["testTargets"] = sorted(set(scheme.get("testTargets", [])) | {TESTS})

    with open(os.path.join(IOS, "project-internal.json"), "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")
    subprocess.run(["xcodegen", "generate", "--spec", "project-internal.json"], cwd=IOS, check=True)
    write_debug_info()


def write_debug_info() -> None:
    """Info-Debug.plist: the Info.plist XcodeGen just wrote, plus NSAllowsLocalNetworking."""
    with open(os.path.join(IOS, INFO), "rb") as f:
        plist = plistlib.load(f)
    plist.setdefault("NSAppTransportSecurity", {})["NSAllowsLocalNetworking"] = True
    with open(os.path.join(IOS, DEBUG_INFO), "wb") as f:
        plistlib.dump(plist, f, sort_keys=True)


if __name__ == "__main__":
    main()
