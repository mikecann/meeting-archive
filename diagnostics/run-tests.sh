#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/.build"
# Use the selected Xcode/Command Line Tools and its matching SDK.
# DEVELOPER_DIR and SDKROOT can override these for a local toolchain workaround.
SWIFTC=$(xcrun --find swiftc)
SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}

mkdir -p "$BUILD_DIR/module-cache"

"$SWIFTC" \
  -sdk "$SDKROOT" \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$SCRIPT_DIR/Sources/CandidateRules.swift" \
  "$SCRIPT_DIR/Tests/CandidateRulesTests.swift" \
  -o "$BUILD_DIR/candidate-rules-tests"

"$BUILD_DIR/candidate-rules-tests"
