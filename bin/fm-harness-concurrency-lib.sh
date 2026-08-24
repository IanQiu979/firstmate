# shellcheck shell=bash
# Per-harness concurrency cap primitives.
# Usage: . bin/fm-harness-concurrency-lib.sh
#
# The captain's own feature request: no more than a configured number of LIVE
# agents on one harness (harness= in state/<id>.meta) at a time, counted across
# every project and task in THIS firstmate home - not per project. Sourced by
# bin/fm-spawn.sh, which calls fm_harness_concurrency_check before it allocates
# any backend session or worktree for a fresh ship/scout spawn or a relaunch.
#
# The count always comes from a live read of state/<id>.meta plus a real
# backend liveness probe (bin/fm-backend.sh's fm_backend_agent_alive), never
# from a separate tally file that could drift out of sync with reality: a
# drifted counter either blocks dispatch forever or silently allows a fourth
# agent, and both failure modes are worse than the cost of a fresh read on
# every spawn.

FM_HARNESS_CONCURRENCY_LIMIT_DEFAULT=3
FM_HARNESS_CONCURRENCY_LIMIT_FILE="harness-concurrency-limit"

fm_harness_concurrency_admission_lock_path() {  # <state-dir> <harness>
  local state=$1 harness=$2
  [ -n "$state" ] || return 1
  case "$state" in *[$'\n\r\t']*) return 1 ;; esac
  case "$harness" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.harness-admission-%s.lock\n' "$state" "$harness"
}

# fm_harness_concurrency_limit: print the effective per-harness cap.
# config/harness-concurrency-limit is a local, gitignored file (see
# docs/configuration.md "Per-harness concurrency cap") holding one positive
# base-10 integer. Absent means the default. Present-but-malformed also falls
# back to the default (with a warning) rather than hard-refusing every spawn
# on a typo - this is a soft-fail input, unlike the recovery-critical
# startup-memory-budget config it otherwise resembles.
fm_harness_concurrency_limit() {  # <config-dir>
  local config=$1 file value
  file="$config/$FM_HARNESS_CONCURRENCY_LIMIT_FILE"
  [ -f "$file" ] || { printf '%s' "$FM_HARNESS_CONCURRENCY_LIMIT_DEFAULT"; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
  case "$value" in
    ''|0|*[!0-9]*)
      echo "warning: config/$FM_HARNESS_CONCURRENCY_LIMIT_FILE ('$value') is not a positive integer; using default $FM_HARNESS_CONCURRENCY_LIMIT_DEFAULT" >&2
      printf '%s' "$FM_HARNESS_CONCURRENCY_LIMIT_DEFAULT"
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

# fm_harness_live_holders: print one task id per line for every task in
# <state-dir> that currently occupies a concurrency slot on <harness>.
#
# What counts as a holder, decided here rather than left to the caller:
#
# - kind=secondmate is EXCLUDED. A secondmate is a persistent per-domain
#   firstmate instance (AGENTS.md section 1), not a project worker dispatched
#   by the handful; it is not what "concurrent agents" means in the captain's
#   request, and counting it would let one long-lived secondmate permanently
#   eat a slot from the ship/scout crew pool the cap is meant to bound.
# - A torn-down task holds no slot without any special-case here: teardown
#   removes state/<id>.meta before this scan can ever see it
#   (bin/fm-teardown.sh), so there is nothing to filter.
# - A recorded-but-DEAD or MISSING endpoint holds no slot. fm_backend_agent_alive
#   maps fm_backend_agent_state's dead/missing verdicts to "dead", and this
#   function drops those - a stale meta file left behind by a crashed agent
#   cannot camp a slot forever and wedge the fleet.
# - alive AND unknown (an ambiguous, unreadable, unverified, or missing-target
#   backend read) both count as holding the slot. This is the fail-closed
#   direction: an inconclusive liveness read means firstmate cannot PROVE the
#   agent is gone, so the cap treats the slot as occupied rather than risk a
#   real fourth agent on a flaky read.
# - <exclude-id>, when given, is skipped outright. A relaunch already proves
#   its own task's endpoint is dead before fm-spawn.sh reaches this check, so
#   the dead-filter above would drop it anyway; excluding it by id is just
#   cheaper and avoids re-probing the task about to be replaced.
fm_harness_live_holders() {  # <state-dir> <harness> [exclude-id]
  local state=$1 harness=$2 exclude=${3:-}
  local meta id kind task_harness backend target alive
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$exclude" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" != secondmate ] || continue
    task_harness=$(fm_meta_get "$meta" harness)
    [ "$task_harness" = "$harness" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    [ "$alive" != dead ] || continue
    printf '%s\n' "$id"
  done
}

# fm_harness_concurrency_check: refuse (stderr message, return 1) when
# <harness> is already at or over its configured cap; otherwise return 0.
# Read-only - it allocates nothing, so a caller can run it before creating any
# backend session, worktree, or metadata and leave nothing to clean up on
# refusal.
fm_harness_concurrency_check() {  # <state-dir> <config-dir> <harness> [exclude-id]
  local state=$1 config=$2 harness=$3 exclude=${4:-}
  local limit holders count ids
  limit=$(fm_harness_concurrency_limit "$config")
  holders=$(fm_harness_live_holders "$state" "$harness" "$exclude")
  count=0
  ids=
  if [ -n "$holders" ]; then
    count=$(printf '%s\n' "$holders" | grep -c .)
    ids=$(printf '%s\n' "$holders" | tr '\n' ' ')
    ids=${ids% }
  fi
  if [ "$count" -ge "$limit" ]; then
    echo "error: harness '$harness' is already at its concurrency cap ($count/$limit live agents: $ids); queue this task instead of spawning a $((count + 1))th" >&2
    return 1
  fi
  return 0
}
