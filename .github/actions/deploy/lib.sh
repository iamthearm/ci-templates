#!/usr/bin/env bash
# Shared helpers for deploy.sh. Sourced, not executed directly.

log() {
  echo "[deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}
