#!/usr/bin/env bash
# Runs ON the VPS, invoked over SSH from the ci-templates 'deploy' composite action.
# Expects to be run with the app's directory as the current working directory, and expects
# docker-compose.yml.new + required-env.txt to already be in place there (scp'd alongside this
# script). It is the single source of truth for the health-check-then-rollback decision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

HEALTH_URL="${1:?usage: deploy.sh <health_url> <retries> <interval_seconds> <timeout_seconds> <expected_status>}"
RETRIES="${2:?}"
INTERVAL="${3:?}"
TIMEOUT="${4:?}"
EXPECTED_STATUS="${5:?}"

APP_DIR="$(pwd)"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
NEW_COMPOSE_FILE="${APP_DIR}/docker-compose.yml.new"
PREV_COMPOSE_FILE="${APP_DIR}/docker-compose.yml.prev"
LAST_GOOD_TAG_FILE="${APP_DIR}/.last-good-tag"
REQUIRED_ENV_FILE="${APP_DIR}/required-env.txt"
ENV_FILE="${APP_DIR}/.env"

log "Deploying in ${APP_DIR}"

check_required_env() {
  [[ -f "${REQUIRED_ENV_FILE}" ]] || return 0
  if [[ ! -s "${REQUIRED_ENV_FILE}" ]]; then
    return 0
  fi
  if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: ${ENV_FILE} does not exist. Create it with the required variables before deploying."
    exit 1
  fi
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if ! grep -qE "^${name}=" "${ENV_FILE}"; then
      log "ERROR: required env var '${name}' is missing from ${ENV_FILE}"
      exit 1
    fi
  done < "${REQUIRED_ENV_FILE}"
}

wait_for_health() {
  local attempt=1
  while (( attempt <= RETRIES )); do
    local status
    status=$(curl -ks -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" "${HEALTH_URL}" || echo "000")
    if [[ "${status}" == "${EXPECTED_STATUS}" ]]; then
      log "Health check passed (status ${status}) on attempt ${attempt}/${RETRIES}"
      return 0
    fi
    log "Health check attempt ${attempt}/${RETRIES} got status ${status}, retrying in ${INTERVAL}s"
    attempt=$((attempt + 1))
    sleep "${INTERVAL}"
  done
  return 1
}

check_required_env

PREV_TAG=""
if [[ -f "${LAST_GOOD_TAG_FILE}" ]]; then
  PREV_TAG=$(cat "${LAST_GOOD_TAG_FILE}")
fi

if [[ -f "${COMPOSE_FILE}" ]]; then
  cp "${COMPOSE_FILE}" "${PREV_COMPOSE_FILE}"
fi
mv "${NEW_COMPOSE_FILE}" "${COMPOSE_FILE}"

NEW_TAG=$(grep -m1 'image:' "${COMPOSE_FILE}" | sed -E 's/.*:([^:[:space:]]+)[[:space:]]*$/\1/')

log "Pulling and starting new version (tag: ${NEW_TAG})"
docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

if wait_for_health; then
  echo "${NEW_TAG}" > "${LAST_GOOD_TAG_FILE}"
  log "Deploy succeeded (tag: ${NEW_TAG})"
  exit 0
fi

log "Health check failed for tag ${NEW_TAG}"

if [[ -z "${PREV_TAG}" ]]; then
  log "FIRST DEPLOY FAILED — no previous state to roll back to. Stopping the service so a broken container isn't left publicly routable."
  docker compose -f "${COMPOSE_FILE}" down
  exit 1
fi

log "Rolling back to previous compose state (last good tag: ${PREV_TAG})"
if [[ -f "${PREV_COMPOSE_FILE}" ]]; then
  cp "${PREV_COMPOSE_FILE}" "${COMPOSE_FILE}"
fi
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

if wait_for_health; then
  log "ROLLBACK SUCCEEDED — reverted to ${PREV_TAG}. This deploy is still reported as FAILED."
  exit 1
else
  log "ROLLBACK FAILED — MANUAL INTERVENTION REQUIRED. Service may be down or degraded. Check 'docker compose -f ${COMPOSE_FILE} logs' on the VPS."
  exit 1
fi
