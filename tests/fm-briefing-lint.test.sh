#!/usr/bin/env bash
# Behavior tests for bin/fm-briefing-lint.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINTER="$ROOT/bin/fm-briefing-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-briefing-lint)

write_clean_briefing() {
  local dir=$1 file
  mkdir -p "$dir"
  file="$dir/2026-08-24.md"
  cat > "$file" <<'EOF'
# Daily Briefing — Monday 2026-08-24
**Status: live**
**Last updated: 10:00 +07** — rewritten on every append.

## Open for the captain
Nothing pending.

## Shipped today
Nothing shipped.

## Broke / went wrong
Nothing broke.

## Still open
Nothing open.

## Log
## 08:00 +07 — Started
Work began at 07:30 +07.
## 08:30 +07 — Continued
Work continued.
## 09:00 +07 — Finished
Work finished.

## Reference
No references.
EOF
  touch -t 202608241200 "$file"
  printf '%s\n' "$file"
}

set_fixture_mtime() {
  touch -t 202608241200 "$1"
}

run_linter() {
  local file=$1 output_file=$2
  set +e
  "$LINTER" "$file" > "$output_file" 2>&1
  RUN_STATUS=$?
  set -e
}

assert_only_finding() {
  local output=$1 check=$2
  grep -Eq "^${check}: " "$output" || fail "$check finding was not reported"
  [ "$(wc -l < "$output" | tr -d ' ')" -eq 1 ] \
    || fail "$check fixture produced findings besides the intended violation: $(cat "$output")"
}

test_clean_file_is_accepted() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/clean")
  output="$TMP_ROOT/clean.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 0 ] || fail "clean briefing exited $RUN_STATUS: $(cat "$output")"
  [ "$(cat "$output")" = OK ] || fail "clean briefing did not print OK: $(cat "$output")"
  pass "fm-briefing-lint: accepts a clean briefing"
}

test_wrong_weekday_is_rejected() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/wrong-weekday")
  sed -i.bak 's/— Monday 2026-08-24/— Tuesday 2026-08-24/' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/wrong-weekday.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "wrong weekday exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" weekday
  pass "fm-briefing-lint: rejects a weekday that does not match the date"
}

test_out_of_order_section_timestamps_are_rejected() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/out-of-order")
  sed -i.bak 's/## 09:00 +07 — Finished/## 08:15 +07 — Finished/' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/out-of-order.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "out-of-order stamps exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" section-order
  pass "fm-briefing-lint: rejects non-ascending stamped sections"
}

test_live_status_requires_three_distinct_stamped_sections() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/false-live")
  sed -i.bak \
    -e '/^## 08:30 +07 /,+1d' \
    -e '/^## 09:00 +07 /,+1d' \
    "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/false-live.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "false live status exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" live-status
  pass "fm-briefing-lint: rejects live status with only one stamped section"
}

test_last_updated_cannot_precede_last_section() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/stale-header")
  sed -i.bak 's/Last updated: 10:00 +07/Last updated: 08:45 +07/' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/stale-header.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "stale header exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" last-updated
  pass "fm-briefing-lint: rejects a last-updated stamp before the last section"
}

test_every_clock_time_requires_the_offset() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/missing-offset")
  sed -i.bak 's/Work began at 07:30 +07\./Work began at 07:30./' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/missing-offset.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "missing offset exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" timezone
  pass "fm-briefing-lint: rejects a clock time without +07"
}

test_credential_patterns_are_rejected() {
  local file output pattern slug
  while IFS='|' read -r slug pattern; do
    file=$(write_clean_briefing "$TMP_ROOT/credential-$slug")
    printf '\nCredential-shaped test placeholder: %s\n' "$pattern" >> "$file"
    set_fixture_mtime "$file"
    output="$TMP_ROOT/credential-$slug.out"
    run_linter "$file" "$output"
    [ "$RUN_STATUS" -eq 1 ] || fail "$slug credential pattern exited $RUN_STATUS instead of 1"
    assert_only_finding "$output" credentials
  done <<'EOF'
anthropic|sk-ant-THIS_IS_FAKE_12345678
hex|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
github-classic|ghp_FAKEPLACEHOLDER
github-fine|github_pat_FAKEPLACEHOLDER
slack|xoxb-FAKEPLACEHOLDER
aws|AKIAFAKEPLACEHOLDER
pem|-----BEGIN FAKE KEY-----
EOF
  pass "fm-briefing-lint: rejects every prohibited credential shape"
}

test_all_six_required_headings_are_required() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/missing-heading")
  sed -i.bak 's/^## Reference$/## Notes/' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/missing-heading.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "missing required heading exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" required-heading
  pass "fm-briefing-lint: rejects a missing required heading"
}

test_bare_pr_reference_requires_matching_https_url() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/bare-pr")
  printf '\nPR #42 shipped.\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/bare-pr.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "bare PR reference exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" pr-url
  pass "fm-briefing-lint: rejects a PR number without its full URL"
}

test_pr_reference_with_matching_https_url_is_accepted() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/linked-pr")
  printf '\nPR #42 shipped: https://github.com/example/project/pull/42\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/linked-pr.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 0 ] || fail "linked PR reference exited $RUN_STATUS: $(cat "$output")"
  [ "$(cat "$output")" = OK ] || fail "linked PR fixture did not print OK"
  pass "fm-briefing-lint: accepts a PR number with its matching full URL"
}

test_exactly_one_h1_is_required() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/extra-h1")
  printf '\n# Accidental second title\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/extra-h1.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "extra h1 exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" h1-count
  pass "fm-briefing-lint: rejects a second h1"
}

test_mtime_date_must_match_filename_without_sealed_marker() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/mtime-mismatch")
  touch -t 202608251200 "$file"
  output="$TMP_ROOT/mtime-mismatch.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "mtime mismatch exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" mtime-date
  pass "fm-briefing-lint: rejects an unsealed file modified on another date"
}

test_sealed_marker_allows_later_mtime() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/sealed-mtime")
  sed -i.bak 's/\*\*Status: live\*\*/**Status: sealed 04:05 +07**\nSEALED 04:05 +07 2026-08-25/' "$file"
  rm "$file.bak"
  touch -t 202608251200 "$file"
  output="$TMP_ROOT/sealed-mtime.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 0 ] || fail "sealed later mtime exited $RUN_STATUS: $(cat "$output")"
  [ "$(cat "$output")" = OK ] || fail "sealed later-mtime fixture did not print OK"
  pass "fm-briefing-lint: permits a sealed file to have a later mtime"
}

test_clean_file_is_accepted
test_wrong_weekday_is_rejected
test_out_of_order_section_timestamps_are_rejected
test_live_status_requires_three_distinct_stamped_sections
test_last_updated_cannot_precede_last_section
test_every_clock_time_requires_the_offset
test_credential_patterns_are_rejected
test_all_six_required_headings_are_required
test_bare_pr_reference_requires_matching_https_url
test_pr_reference_with_matching_https_url_is_accepted
test_exactly_one_h1_is_required
test_mtime_date_must_match_filename_without_sealed_marker
test_sealed_marker_allows_later_mtime
