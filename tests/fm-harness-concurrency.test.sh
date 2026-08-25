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
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
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
. "$WAKE_LIB"
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
  printf '000\n' > "$home/config/harness-concurrency-limit"
  [ "$(fm_harness_concurrency_limit "$home/config" 2>/dev/null)" = 3 ] \
    || fail "an all-zero config value like '000' should fall back to the default, not silently zero the cap"
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

test_concurrent_admission_publishes_only_one_final_slot() {
  local home id1 id2 result_a result_b success_count
  home=$(new_home concurrent-admission)
  id1=hc-concurrent-a-q1
  id2=hc-concurrent-b-q2
  new_alive_window "hc-concurrent-1" claude-link
  new_alive_window "hc-concurrent-2" claude-link
  wait_for_alive "$SESSION:hc-concurrent-1" || fail "fixture window hc-concurrent-1 never went alive"
  wait_for_alive "$SESSION:hc-concurrent-2" || fail "fixture window hc-concurrent-2 never went alive"
  fm_write_meta "$home/state/hc-concurrent-existing-a-q1.meta" "window=$SESSION:hc-concurrent-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/hc-concurrent-existing-b-q2.meta" "window=$SESSION:hc-concurrent-2" "harness=claude" "kind=ship"

  admission_worker() {
    local id=$1 endpoint=$2 lock
    lock=$(fm_harness_concurrency_admission_lock_path "$home/state" claude) || return 1
    fm_lock_acquire_wait "$lock" || return 1
    if fm_harness_concurrency_check "$home/state" "$home/config" claude; then
      fm_write_meta "$home/state/$id.meta" "window=$endpoint" "harness=claude" "kind=ship"
      fm_lock_release "$lock"
      return 0
    fi
    fm_lock_release "$lock"
    return 1
  }

  admission_worker "$id1" "$SESSION:hc-concurrent-1" >"$home/a.out" 2>&1 &
  local pid_a=$!
  admission_worker "$id2" "$SESSION:hc-concurrent-2" >"$home/b.out" 2>&1 &
  local pid_b=$!
  wait "$pid_a" && result_a=success || result_a=refused
  wait "$pid_b" && result_b=success || result_b=refused
  success_count=0
  [ "$result_a" = success ] && success_count=$((success_count + 1))
  [ "$result_b" = success ] && success_count=$((success_count + 1))
  [ "$success_count" -eq 1 ] || fail "two simultaneous admissions with two live holders must publish exactly one final slot"
  [ "$(fm_harness_live_holders "$home/state" claude | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "atomic admission must leave exactly three live claude slots"
  pass "concurrent admission: two contenders at 2/3 publish exactly one final slot"
}

# --- admission lock must span the create-pane-then-launch-later gap ---------
#
# bin/fm-spawn.sh creates the new endpoint's pane, publishes its meta, and only
# THEN sends the actual launch command into it - so right after meta
# publication the freshly created pane is still a bare shell (reads "dead"
# until the launch command actually starts the agent process). A worker that
# releases its admission lock at publish time (instead of after the launch
# command is sent) lets a second admission scan run during that gap, see the
# first worker's new pane as dead, and wrongly admit past the cap. This
# reproduces that exact shape with a real tmux window and a real delayed
# transition from dead to alive, using the SAME lock/check/publish/release
# primitives fm-spawn.sh uses, held across the gap the way the fix requires.
test_admission_lock_spans_dead_window_before_launch() {
  local home id1 id2 result_a result_b success_count
  home=$(new_home lock-spans-gap)
  id1=hc-gap-a-q1
  id2=hc-gap-b-q2
  new_alive_window "hc-gap-1" claude-link
  new_alive_window "hc-gap-2" claude-link
  wait_for_alive "$SESSION:hc-gap-1" || fail "fixture window hc-gap-1 never went alive"
  wait_for_alive "$SESSION:hc-gap-2" || fail "fixture window hc-gap-2 never went alive"
  fm_write_meta "$home/state/hc-gap-existing-a-q1.meta" "window=$SESSION:hc-gap-1" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/hc-gap-existing-b-q2.meta" "window=$SESSION:hc-gap-2" "harness=claude" "kind=ship"

  # Simulates fm-spawn.sh's real sequence: admit -> create a bare-shell pane ->
  # publish meta pointing at it (still dead) -> only later actually launch the
  # agent into it (now alive) -> release the admission lock.
  spawn_like_worker() {
    local id=$1 window=$2 lock
    lock=$(fm_harness_concurrency_admission_lock_path "$home/state" claude) || return 1
    fm_lock_acquire_wait "$lock" || return 1
    if ! fm_harness_concurrency_check "$home/state" "$home/config" claude; then
      fm_lock_release "$lock"
      return 1
    fi
    new_dead_window "$window"
    fm_write_meta "$home/state/$id.meta" "window=$SESSION:$window" "harness=claude" "kind=ship"
    wait_for_dead "$SESSION:$window" || true
    sleep 0.3
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$window" \
      "exec $LAB/bin/claude-link 900" Enter
    wait_for_alive "$SESSION:$window" || true
    fm_lock_release "$lock"
    return 0
  }

  spawn_like_worker "$id1" hc-gap-new-1 >"$home/a.out" 2>&1 &
  local pid_a=$!
  spawn_like_worker "$id2" hc-gap-new-2 >"$home/b.out" 2>&1 &
  local pid_b=$!
  wait "$pid_a" && result_a=success || result_a=refused
  wait "$pid_b" && result_b=success || result_b=refused
  success_count=0
  [ "$result_a" = success ] && success_count=$((success_count + 1))
  [ "$result_b" = success ] && success_count=$((success_count + 1))
  [ "$success_count" -eq 1 ] \
    || fail "a racing admission during the dead-pane-before-launch gap must not both be admitted at a cap of 3 with 2 existing holders plus 1 remaining slot"
  [ "$(fm_harness_live_holders "$home/state" claude | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "the admission lock spanning the dead-window gap must leave exactly three live claude slots (2 pre-existing + 1 admitted)"
  pass "admission lock spans the dead-pane-before-launch gap: a racing admission during it is refused"
}

test_missing_zellij_endpoint_does_not_hold_slot() {
  local home fake_zellij old_path holders
  home=$(new_home zellij-missing)
  fake_zellij="$home/zellij"
  old_path=$PATH
  cat > "$fake_zellij" <<'SH'
#!/usr/bin/env bash
if [ "$1" = list-sessions ]; then
  printf 'zellij-fixture\n'
  exit 0
fi
if [ "$1" = --session ] && [ "$3" = action ] && [ "$4" = list-panes ] && [ "$5" = --json ]; then
  printf '[]\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fake_zellij"
  PATH="$home:$PATH"
  export PATH
  fm_write_meta "$home/state/hc-zellij-stale-q1.meta" \
    "window=zellij-fixture:99" "backend=zellij" "harness=claude" "kind=ship"
  [ "$(fm_backend_agent_state zellij zellij-fixture:99)" = missing ] \
    || fail "a readable Zellij session lacking the recorded pane must be missing"
  holders=$(fm_harness_live_holders "$home/state" claude)
  [ -z "$holders" ] || fail "a missing Zellij endpoint must not hold a harness slot"
  PATH=$old_path
  export PATH
  pass "missing Zellij endpoint: a stale record does not hold a concurrency slot"
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
test_concurrent_admission_publishes_only_one_final_slot
test_admission_lock_spans_dead_window_before_launch
test_missing_zellij_endpoint_does_not_hold_slot
test_secondmates_are_excluded

echo "# all fm-harness-concurrency tests passed"
