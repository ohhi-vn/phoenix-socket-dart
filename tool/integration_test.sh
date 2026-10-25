#!/usr/bin/env bash
#
# Starts the Toxiproxy proxy and the example Phoenix backend, waits until both
# are ready, runs the test suite, and tears the services down again.
#
# Usage:
#   tool/integration_test.sh                # run the whole suite
#   tool/integration_test.sh test/channel_integration_test.dart
#
# Environment:
#   INTEGRATION_TIMEOUT   readiness deadline in seconds (default: 120)
#   INTEGRATION_REUSE     set to 1 to use an already running stack and skip
#                         port checks/teardown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/test-compose.yaml"
BACKEND_URL="http://localhost:4001/"
PROXY_URL="http://localhost:8474/proxies"
TIMEOUT="${INTEGRATION_TIMEOUT:-120}"
REUSE="${INTEGRATION_REUSE:-0}"

fail() {
  echo "error: $*" >&2
  exit 1
}

detect_compose() {
  RUNTIME=""
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
    RUNTIME=docker
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
    RUNTIME=docker
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE=(podman compose)
    RUNTIME=podman
  else
    fail "no container runtime found. Install Docker Desktop (with the compose plugin), docker-compose, or podman compose, then retry."
  fi

  # Prefer a working runtime: fall back to podman when the Docker daemon is
  # installed but not running.
  if [[ "${RUNTIME}" == "docker" ]] && ! docker info >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1 &&
      podman info >/dev/null 2>&1 &&
      podman compose version >/dev/null 2>&1; then
      echo "The Docker daemon is unavailable; using podman compose instead."
      COMPOSE=(podman compose)
      RUNTIME=podman
    fi
  fi
}

ensure_runtime_running() {
  case "${RUNTIME}" in
    podman)
      podman info >/dev/null 2>&1 ||
        fail "podman is installed but its machine/service is not running. Start it with 'podman machine start' and retry."
      ;;
    *)
      docker info >/dev/null 2>&1 ||
        fail "the Docker daemon is not running. Start Docker Desktop (or the docker service), start podman, or retry with a compose runtime that is running."
      ;;
  esac
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
  else
    return 1
  fi
}

compose() {
  "${COMPOSE[@]}" -f "${COMPOSE_FILE}" "$@"
}

service_running() {
  local service="$1"
  compose ps --services --filter status=running 2>/dev/null | grep -qx "${service}"
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local service="$3"
  local deadline=$((SECONDS + TIMEOUT))

  while ((SECONDS < deadline)); do
    if curl -sS -o /dev/null --max-time 2 "${url}" 2>/dev/null; then
      echo "  ${name} is ready (${url})"
      return 0
    fi
    if ! service_running "${service}"; then
      echo "--- ${service} logs ---" >&2
      compose logs --tail=30 "${service}" >&2 || true
      fail "${name} (service '${service}') exited before becoming ready. Check the logs above and that ports 4001/4002 are free."
    fi
    sleep 1
  done

  echo "--- ${service} logs ---" >&2
  compose logs --tail=30 "${service}" >&2 || true
  fail "${name} did not become ready within ${TIMEOUT}s at ${url}. Increase INTEGRATION_TIMEOUT or inspect the logs above."
}

cd "${ROOT_DIR}"

detect_compose

STARTED=0
cleanup() {
  local status=$?
  if [[ "${STARTED}" == "1" ]]; then
    echo "Stopping integration services..."
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

if [[ "${REUSE}" == "1" ]]; then
  echo "Reusing the running integration stack (INTEGRATION_REUSE=1)."
  STARTED=0
else
  if compose ps --services --filter status=running 2>/dev/null | grep -q .; then
    echo "An integration stack from this compose file is already running; reusing it."
    STARTED=0
  else
    for port in 4001 4002 4004 8474; do
      if port_in_use "${port}"; then
        fail "port ${port} is already in use. Stop the process using it, or set INTEGRATION_REUSE=1 to use an existing stack."
      fi
    done
    ensure_runtime_running
    echo "Starting Toxiproxy and the Phoenix backend..."
    STARTED=1
    compose up -d --build
  fi
fi

wait_for_url "Phoenix backend" "${BACKEND_URL}" "backend"
wait_for_url "Toxiproxy" "${PROXY_URL}" "proxy"

echo "Running tests..."
dart test "$@"
