#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift run --package-path "$PROJECT_DIR" --build-path "${MEETING_BUILD_PATH:-/tmp/MeetingSidekick-build}" MeetingChecks
