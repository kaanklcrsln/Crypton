#!/bin/bash
# Builds and runs the Crypton test suite against real encrypted vaults.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
echo "==> Building tests"
swiftc -O -o "$ROOT/build/crypton-tests" \
  "$ROOT"/Crypton/Sources/CryptonCore/*.swift \
  "$ROOT"/Crypton/Tests/main.swift
echo "==> Running"
"$ROOT/build/crypton-tests"
