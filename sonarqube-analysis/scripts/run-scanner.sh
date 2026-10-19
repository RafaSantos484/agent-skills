#!/usr/bin/env bash
#
# Standalone, interactive SonarScanner launcher.
#
# Resolves the SonarQube server URL and auth token from the SONAR_HOST_URL and
# SONAR_TOKEN environment variables. When either is missing, it prompts for
# the value interactively so an occasional manual run does not require
# exporting the variables first:
#   - SONAR_HOST_URL prompts with a default of http://localhost:9000 — press
#     Enter to accept it.
#   - SONAR_TOKEN prompts with hidden input (never echoed) and has no
#     default; it must be typed or already exported.
#
# Runs the analysis via the official sonarsource/sonar-scanner-cli Docker
# image rather than requiring a native SonarScanner CLI install. The current
# working directory is bind-mounted read-write into the container at
# /usr/src (the path the image expects sources at), and --network host is
# used so a SONAR_HOST_URL of http://localhost:9000 reaches a SonarQube
# server running on the same machine. --network host is Linux-only; on
# Docker Desktop (macOS/Windows) point SONAR_HOST_URL at
# host.docker.internal instead and drop --network host.
#
# Security: the token is never echoed to the terminal and is handed to the
# scanner through its child-process environment via `docker run -e VAR`
# (no `=value`), which forwards the value from the calling environment
# without ever placing it in argv or `docker inspect` output.
#
# Usage: bash run-scanner.sh   (run from the project root)

set -euo pipefail

DEFAULT_HOST_URL="http://localhost:9000"

resolve_host_url() {
  if [ -n "${SONAR_HOST_URL:-}" ]; then
    printf '%s' "$SONAR_HOST_URL"
    return
  fi

  if [ ! -t 0 ]; then
    printf '%s' "$DEFAULT_HOST_URL"
    return
  fi

  read -r -p "SonarQube host URL (SONAR_HOST_URL) [$DEFAULT_HOST_URL]: " input
  printf '%s' "${input:-$DEFAULT_HOST_URL}"
}

resolve_token() {
  if [ -n "${SONAR_TOKEN:-}" ]; then
    printf '%s' "$SONAR_TOKEN"
    return
  fi

  if [ ! -t 0 ]; then
    echo "SONAR_TOKEN is not set and no interactive terminal is available to prompt for it." >&2
    exit 1
  fi

  local value=""
  while [ -z "$value" ]; do
    read -r -s -p "SonarQube token (SONAR_TOKEN): " value
    echo >&2
    [ -z "$value" ] && echo "SONAR_TOKEN cannot be empty." >&2
  done
  printf '%s' "$value"
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found on PATH. Install Docker, then re-run this script." >&2
  exit 1
fi

HOST_URL="$(resolve_host_url)"
TOKEN="$(resolve_token)"

DOCKER_ARGS=(
  run --rm --network host
  -e SONAR_HOST_URL
  -e SONAR_TOKEN
  -v "$(pwd):/usr/src"
)

# Match the container process to the host user/group so files written into
# the bind-mounted project (e.g. .scannerwork/) aren't owned by root.
if command -v id >/dev/null 2>&1; then
  DOCKER_ARGS+=(--user "$(id -u):$(id -g)")
fi

DOCKER_ARGS+=(sonarsource/sonar-scanner-cli)

SONAR_HOST_URL="$HOST_URL" SONAR_TOKEN="$TOKEN" docker "${DOCKER_ARGS[@]}"
