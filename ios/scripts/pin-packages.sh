#!/bin/zsh
# Refresh ios/Package.resolved, the package pins Xcode Cloud builds with (ci_scripts/ci_post_clone.sh copies it into the
# generated project, because Xcode Cloud never resolves packages itself). Run it after changing a package requirement in
# project.yml or DyorKit/Package.swift, then commit Package.resolved.
#
# Pins that still satisfy the requirements are kept; changed requirements are re-resolved. The committed pins are seeded
# into the project first because a freshly generated project has no pin file of its own, and Xcode then resolves
# against DyorKit/Package.resolved and never writes one.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
RESOLVED=DyorHQ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p ${RESOLVED:h}
cp Package.resolved $RESOLVED
xcodebuild -resolvePackageDependencies -project DyorHQ.xcodeproj -scheme DyorHQ | grep -E "^  .+@ |error:" || true
cp $RESOLVED Package.resolved
git diff --stat -- Package.resolved
