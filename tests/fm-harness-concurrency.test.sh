#!/usr/bin/env bash
# Behavior tests for the per-harness concurrency cap (bin/fm-harness-concurrency-lib.sh,
# wired into bin/fm-spawn.sh): no more than a configured number of LIVE agents
# on one harness at a time, counted across every project and task in a home.
#
# The count comes from a live read (state/*.meta plus a real backend liveness
# probe), not a tally file, so these fixtures use a REAL tmux server on a
# private socket (`-L`), the same technique as
# tests/fm-tmux-agent-liveness.test.sh and tests/fm-backend-tmux-smoke.test.sh:
# a symlinked long-running binary named like a verified harness reads as
# "alive", an idle default shell reads as "dead", and a window that was never
# created reads as "missing" (also folded into "dead" for cap purposes).
#
# fm-spawn.sh's cap check runs before any backend session, worktree, or
# metadata is allocated for the NEW task, so a refused spawn is asserted to
# leave the new task's own state/meta and tmux window absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
LIB="$ROOT/bin/fm-harness-concurrency-lib.sh"
BACKEND_LIB="$ROOT/bin/fm-backend.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-hconc-$$"
TMP_ROOT=$(fm_test_tmproot fm-harness-concurrency)
LAB="$TMP_ROOT/lab"
SESSION=hconc

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# Stand-in harness binaries: symlinks to a real long-running system binary
# (never a copy - a copied platform binary fails macOS code-signing and is
# killed), named so the tmux classifier reads them as a verified harness.
ln -s "$SLEEP_BIN" "$LAB/bin/claude-link"
ln -s "$SLEEP_BIN" "$LAB/bin/codex-link"

# shellcheck source=/dev/null
. "$BACKEND_LIB"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=/dev/null
. "$LIB"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n boot -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# <window-name> <harness-link> -> a live window whose foreground process
# classifies as that harness (fm_backend_tmux_classify_process_name: agent).
new_alive_window() {
  local name=$1 link=$2
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" \
    -- "$LAB/bin/$link" 900 || fail "could not create alive window $name"
}

# <window-name> -> an idle default shell, which classifies as dead.
new_dead_window() {
  local name=$1
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" \
    || fail "could not create dead window $name"
}

wait_for_alive() {  # <target>
  local target=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ "$(fm_backend_agent_state tmux "$target")" = alive ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_dead() {  # <target> - settles to fm_backend_agent_state's dead OR
                    # missing, the two verdicts fm_backend_agent_alive folds
                    # into "dead" for cap purposes.
  local target=$1 i=0
  while [ "$i" -lt 100 ]; do
    case "$(fm_backend_agent_state tmux "$target")" in
      dead|missing) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Fresh per-test home: state/config/data/projects, independent of the shared
# tmux session/socket above (only the fixture meta "window=" fields tie back
# to it).
new_home() {  # <label>
  local home="$TMP_ROOT/home-$1"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects/alpha"
  printf '%s\n' "$home"
}

run_spawn() {  # <home> <id> <harness>
  local home=$1 id=$2 harness=$3
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$id" projects/alpha "$harness" --mode no-mistakes --yolo off 2>&1
}

# --- fm_harness_concurrency_limit: config parsing, sourced directly ---------

test_limit_defaults_and_validates() {
  local home
  home=$(new_home limit)
  [ "$(fm_harness_concurrency_limit "$home/config")" = 3 ] \
    || fail "absent config/harness-concurrency-limit should default to 3"
  printf '5\n' > "$home/config/harness-concurrency-limit"
  [ "$(fm_harness_concurrency_limit "$home/config")" = 5 ] \
    || fail "a valid config value should be honored"
  printf 'nope\n' > "$home/config/harness-concurrency-limit"
  [ "$(fm_harness_concurrency_limit "$home/config" 2>/dev/null)" = 3 ] \
    || fail "a malformed config value should fall back to the default"
  pass "fm_harness_concurrency_limit: absent -> 3, valid value honored, malformed falls back"
}

# --- under cap: 2 live claude holders, a 3rd is allowed through -------------

test_under_cap_allows_spawn() {
  local home id1 id2 out
  home=$(new_home under-cap)
  id1=hc-under-a-q1
  id2=hc-under-b-q2
  new_alive_window "hc-under-1" claude-link
  new_alive_window "hc-under-2" claude-link
  wait_for_alive "$SESSION:hc-under-1" || fail "fixture window hc-under-1 never went alive"
  wait_for_alive "$SESSION:hc-under-2" || fail "fixture window hc-under-2 never went alive"
  fm_write_meta "$home/state/$id1.meta" "window=$SESSION:hc-under-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id2.meta" "window=$SESSION:hc-under-2" "harness=claude" "kind=ship"

  out=$(run_spawn "$home" hc-under-new-q3 claude)
  assert_not_contains "$out" "concurrency cap" "2 live holders (under the default cap of 3) should not refuse a 3rd"
  assert_contains "$out" "no brief at" "spawn should proceed past the cap check to the next real gate"
  pass "under cap: a 3rd claude spawn is not refused by the concurrency check"
}

# --- at cap: 3 live claude holders refuse a 4th, naming harness/count/ids ---

test_at_cap_refuses_and_names_holders() {
  local home id1 id2 id3 new_id out status
  home=$(new_home at-cap)
  id1=hc-at-a-q1
  id2=hc-at-b-q2
  id3=hc-at-c-q3
  new_id=hc-at-new-q4
  new_alive_window "hc-at-1" claude-link
  new_alive_window "hc-at-2" claude-link
  new_alive_window "hc-at-3" claude-link
  wait_for_alive "$SESSION:hc-at-1" || fail "fixture window hc-at-1 never went alive"
  wait_for_alive "$SESSION:hc-at-2" || fail "fixture window hc-at-2 never went alive"
  wait_for_alive "$SESSION:hc-at-3" || fail "fixture window hc-at-3 never went alive"
  fm_write_meta "$home/state/$id1.meta" "window=$SESSION:hc-at-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id2.meta" "window=$SESSION:hc-at-2" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id3.meta" "window=$SESSION:hc-at-3" "harness=claude" "kind=ship"

  out=$(run_spawn "$home" "$new_id" claude)
  status=$?
  expect_code 1 "$status" "a 4th claude spawn at the cap must be refused"
  assert_contains "$out" "error: harness 'claude' is already at its concurrency cap" "refusal must name the harness"
  assert_contains "$out" "(3/3 live agents:" "refusal must name the live count and limit"
  assert_contains "$out" "$id1" "refusal must name holding task id 1"
  assert_contains "$out" "$id2" "refusal must name holding task id 2"
  assert_contains "$out" "$id3" "refusal must name holding task id 3"
  assert_absent "$home/state/$new_id.meta" "a refused spawn must not leave metadata behind"
  assert_absent "$home/data/$new_id" "a refused spawn must not leave a data/<id> directory behind"
  "$REAL_TMUX" -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' \
    | grep -qx "fm-$new_id" && fail "a refused spawn must not leave a backend window behind"
  pass "at cap: a 4th claude spawn is refused, naming the harness, count, and holding task ids"
}

# --- over cap: a lowered limit still reports real counts against it --------

test_over_cap_reports_correctly() {
  local home id1 id2 id3 out
  home=$(new_home over-cap)
  id1=hc-over-a-q1
  id2=hc-over-b-q2
  id3=hc-over-c-q3
  printf '2\n' > "$home/config/harness-concurrency-limit"
  new_alive_window "hc-over-1" claude-link
  new_alive_window "hc-over-2" claude-link
  new_alive_window "hc-over-3" claude-link
  wait_for_alive "$SESSION:hc-over-1" || fail "fixture window hc-over-1 never went alive"
  wait_for_alive "$SESSION:hc-over-2" || fail "fixture window hc-over-2 never went alive"
  wait_for_alive "$SESSION:hc-over-3" || fail "fixture window hc-over-3 never went alive"
  fm_write_meta "$home/state/$id1.meta" "window=$SESSION:hc-over-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id2.meta" "window=$SESSION:hc-over-2" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id3.meta" "window=$SESSION:hc-over-3" "harness=claude" "kind=ship"

  out=$(run_spawn "$home" hc-over-new-q4 claude)
  assert_contains "$out" "(3/2 live agents:" "a cap lowered below the live count must still refuse and report the real 3/2 count"
  pass "over cap: 3 live agents against a lowered limit of 2 still refuses and reports 3/2"
}

# --- mixed harnesses: claude at cap does not block codex --------------------

test_mixed_harnesses_are_independent() {
  local home id1 id2 id3 out
  home=$(new_home mixed)
  id1=hc-mix-a-q1
  id2=hc-mix-b-q2
  id3=hc-mix-c-q3
  new_alive_window "hc-mix-1" claude-link
  new_alive_window "hc-mix-2" claude-link
  new_alive_window "hc-mix-3" claude-link
  wait_for_alive "$SESSION:hc-mix-1" || fail "fixture window hc-mix-1 never went alive"
  wait_for_alive "$SESSION:hc-mix-2" || fail "fixture window hc-mix-2 never went alive"
  wait_for_alive "$SESSION:hc-mix-3" || fail "fixture window hc-mix-3 never went alive"
  fm_write_meta "$home/state/$id1.meta" "window=$SESSION:hc-mix-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id2.meta" "window=$SESSION:hc-mix-2" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/$id3.meta" "window=$SESSION:hc-mix-3" "harness=claude" "kind=ship"

  out=$(run_spawn "$home" hc-mix-new-q4 codex)
  assert_not_contains "$out" "concurrency cap" "claude at cap must not block a codex spawn"
  assert_contains "$out" "no brief at" "codex spawn should proceed past the cap check to the next real gate"
  pass "mixed harnesses: claude at cap does not refuse a codex spawn (per-harness, not global)"
}

# --- dead/missing endpoints hold no slot -------------------------------------

test_dead_and_missing_endpoints_do_not_hold_slots() {
  local home id1 id2 id3 out
  home=$(new_home dead)
  id1=hc-dead-a-q1
  id2=hc-dead-b-q2
  id3=hc-dead-c-q3
  new_dead_window "hc-dead-1"
  wait_for_dead "$SESSION:hc-dead-1" || fail "fixture window hc-dead-1 never settled dead"
  fm_write_meta "$home/state/$id1.meta" "window=$SESSION:hc-dead-1" "harness=claude" "kind=ship"
  # id2's endpoint holds a window that was never created (missing).
  fm_write_meta "$home/state/$id2.meta" "window=$SESSION:hc-dead-never-created" "harness=claude" "kind=ship"
  wait_for_dead "$SESSION:hc-dead-never-created" || fail "a never-created window should read missing/dead"
  # id3's endpoint holds a window in a session that does not exist at all.
  fm_write_meta "$home/state/$id3.meta" "window=ghost-session:ghost-window" "harness=claude" "kind=ship"

  out=$(run_spawn "$home" hc-dead-new-q4 claude)
  assert_not_contains "$out" "concurrency cap" "3 recorded-but-dead/missing claude tasks must not hold slots"
  assert_contains "$out" "no brief at" "spawn should proceed past the cap check to the next real gate"
  pass "dead/missing endpoints: 3 stale claude records do not block a fresh spawn"
}

# --- secondmates are excluded from the count ---------------------------------

test_secondmates_are_excluded() {
  local home id1 id2 id3 out
  home=$(new_home secondmate)
  id1=hc-sm-a-q1
  id2=hc-sm-b-q2
  id3=hc-sm-c-q3
  new_alive_window "hc-sm-1" claude-link
  new_alive_window "hc-sm-2" claude-link
  new_alive_window "hc-sm-3" claude-link
  wait_for_alive "$SESSION:hc-sm-1" || fail "fixture window hc-sm-1 never went alive"
  wait_for_alive "$SESSION:hc-sm-2" || fail "fixture window hc-sm-2 never went alive"
  wait_for_alive "$SESSION:hc-sm-3" || fail "fixture window hc-sm-3 never went alive"
  fm_write_secondmate_meta "$home/state/$id1.meta" "$home" "$SESSION:hc-sm-1" alpha claude
  fm_write_secondmate_meta "$home/state/$id2.meta" "$home" "$SESSION:hc-sm-2" alpha claude
  fm_write_secondmate_meta "$home/state/$id3.meta" "$home" "$SESSION:hc-sm-3" alpha claude

  out=$(run_spawn "$home" hc-sm-new-q4 claude)
  assert_not_contains "$out" "concurrency cap" "3 live secondmates on claude must not count against the crewmate cap"
  assert_contains "$out" "no brief at" "spawn should proceed past the cap check to the next real gate"
  pass "secondmates are excluded: 3 live claude secondmates do not block a claude ship spawn"
}

test_limit_defaults_and_validates
test_under_cap_allows_spawn
test_at_cap_refuses_and_names_holders
test_over_cap_reports_correctly
test_mixed_harnesses_are_independent
test_dead_and_missing_endpoints_do_not_hold_slots
test_secondmates_are_excluded

echo "# all fm-harness-concurrency tests passed"
