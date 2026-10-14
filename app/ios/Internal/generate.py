#!/usr/bin/env python3
"""Generates DyorHQInternal.xcodeproj: the DyorHQ app with DyorHQ Lite (Stellar), for the internal TestFlight group.

It is a separate project on purpose. Xcode resolves every package a project references, whichever target links it,
and the App Store app is built from the public DyorHQ/IOS-app repository, which doesn't have the Lite packages, so
the App Store project (project.yml → DyorHQ.xcodeproj) must never reference them. A compile flag can't unlink a
package either.

project.yml stays the single source of truth: this script takes XcodeGen's resolved dump of it, adds Lite to the
DyorHQ target (the two packages, STELLAR_LITE, the Lite API URL, its own Info.plist), writes project-internal.json
(git-ignored) and generates DyorHQInternal.xcodeproj next to DyorHQ.xcodeproj, so $(SRCROOT) means the same in both.

This app lives in the private DyorHQ/multichain-stellar repository, as app/ (a copy of the public app, updated with
git subtree pull --prefix=app), next to the Lite packages in ios/Packages. From app/ios/:
    python3 Internal/generate.py                      # from project.yml
    python3 Internal/generate.py --spec other.yml     # e.g. a local spec without the secrets config
"""
import argparse
import json
import os
import subprocess

IOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spec", default="project.yml", help="the app's XcodeGen spec, relative to ios/")
    ap.add_argument("--lite", default="../../ios/Packages",
                    help="multichain-stellar's ios/Packages, relative to app/ios/")
    args = ap.parse_args()

    for package in ("StellarKit", "DyorLite"):
        if not os.path.isfile(os.path.join(IOS, args.lite, package, "Package.swift")):
            raise SystemExit(f"{package} not found under {args.lite} (relative to app/ios/): run this from the multichain-stellar repository")

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
    info["path"] = "Internal/Info.plist"
    info["properties"].update({
        # The Lite API: the local stack in Debug (docs/RUNBOOK-testnet.md in multichain-stellar), the DyorHQ project's
        # lite function in Release. A public URL, no key.
        "LITE_API_URL": "$(LITE_API_URL)",
        # Debug only: shows the network switch without the `stellarLite` remote flag (empty in Release, and Release
        # code ignores it anyway).
        "LiteDebugForceOn": "$(DYOR_DEBUG_LITE_FORCE_ON)",
        # The simulator reaches the local Lite API over plain HTTP on 127.0.0.1.
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    })

    settings = target.setdefault("settings", {})
    settings.setdefault("base", {})["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) STELLAR_LITE"
    configs = settings.setdefault("configs", {})
    configs.setdefault("Debug", {}).update({
        "LITE_API_URL": "http:/$()/127.0.0.1:8000/lite",
        "DYOR_DEBUG_LITE_FORCE_ON": "YES",
    })
    configs.setdefault("Release", {}).update({
        "LITE_API_URL": "https:/$()/fmnjqrguvopusfufmirs.supabase.co/functions/v1/lite",
        "DYOR_DEBUG_LITE_FORCE_ON": "",
    })

    with open(os.path.join(IOS, "project-internal.json"), "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")
    subprocess.run(["xcodegen", "generate", "--spec", "project-internal.json"], cwd=IOS, check=True)


if __name__ == "__main__":
    main()
