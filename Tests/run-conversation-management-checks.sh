#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/feiq-conversation-checks.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT

sources=(
    "$project_root"/FeiQMac/Models/*.swift
    "$project_root"/FeiQMac/Protocol/*.swift
    "$project_root"/FeiQMac/Network/*.swift
    "$project_root"/FeiQMac/Services/*.swift
    "$project_root"/FeiQMac/Persistence/*.swift
    "$project_root"/FeiQMac/Repositories/*.swift
    "$project_root"/FeiQMac/ViewModels/*.swift
)
flags=(-swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$build_root/modules")

echo "Running conversation management checks"
xcrun swiftc "${flags[@]}" "${sources[@]}" \
    "$project_root/Tests/ConversationManagementChecks.swift" -lsqlite3 -o "$build_root/ConversationManagementChecks"
"$build_root/ConversationManagementChecks"

echo "Type-checking the macOS application"
xcrun swiftc "${flags[@]}" -typecheck "${sources[@]}" \
    "$project_root"/FeiQMac/Views/*.swift \
    "$project_root/FeiQMac/FeiQMacApp.swift"
echo "All conversation management checks passed"
