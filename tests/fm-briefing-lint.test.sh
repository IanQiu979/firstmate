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

**Last updated: 10:00 +07**

## Fleet state

Work began at 07:30 +07.

- none

## Open

- none

## Shipped

- none

## Broke

- none

## Reference

- none

### Log

- 09:00 +07 nothing to report.
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

test_missing_last_updated_stamp_is_rejected() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/missing-last-updated")
  sed -i.bak 's/^\*\*Last updated: 10:00 +07\*\*$/**Last updated: today**/' "$file"
  rm "$file.bak"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/missing-last-updated.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "missing last-updated stamp exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" last-updated
  pass "fm-briefing-lint: rejects a header without a Last updated: HH:MM +07 stamp"
}

test_every_template_heading_is_required() {
  local file output heading
  for heading in 'Fleet state' 'Open' 'Shipped' 'Broke' 'Reference'; do
    file=$(write_clean_briefing "$TMP_ROOT/missing-${heading// /-}")
    sed -i.bak "/^## ${heading}\$/d" "$file"
    rm "$file.bak"
    set_fixture_mtime "$file"
    output="$TMP_ROOT/missing-${heading// /-}.out"
    run_linter "$file" "$output"
    [ "$RUN_STATUS" -eq 1 ] || fail "missing ## $heading exited $RUN_STATUS instead of 1"
    assert_only_finding "$output" required-heading
    grep -Fq "missing ## $heading" "$output" \
      || fail "missing ## $heading was not named in the finding: $(cat "$output")"
  done
  pass "fm-briefing-lint: rejects a briefing missing any of the five template headings"
}

test_unexpected_h2_heading_is_rejected() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/unexpected-heading")
  printf '\n## Notes\n\n- none\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/unexpected-heading.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "unexpected heading exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" unexpected-heading
  grep -Fq '## Notes is not one of the 5 fixed sections' "$output" \
    || fail "unexpected heading finding did not name the five-section contract: $(cat "$output")"
  pass "fm-briefing-lint: rejects an h2 heading outside the template"
}

test_h3_subsections_are_not_flagged() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/h3-subsections")
  printf '\n### HANDOFF\n\n- read this first.\n\n#### Deeper\n\n- none\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/h3-subsections.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 0 ] || fail "h3 subsections exited $RUN_STATUS: $(cat "$output")"
  [ "$(cat "$output")" = OK ] || fail "h3 subsection fixture did not print OK"
  pass "fm-briefing-lint: leaves h3 and deeper subsections free-form"
}

test_duplicate_template_heading_is_rejected() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/duplicate-heading")
  printf '\n## Open\n\n- none\n' >> "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/duplicate-heading.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "duplicate heading exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" duplicate-heading
  pass "fm-briefing-lint: rejects a template heading that appears twice"
}

test_template_headings_must_keep_their_order() {
  local file output
  file=$(write_clean_briefing "$TMP_ROOT/heading-order")
  awk '
    /^## Shipped$/ { print "## Broke"; next }
    /^## Broke$/ { print "## Shipped"; next }
    { print }
  ' "$file" > "$file.swapped"
  mv "$file.swapped" "$file"
  set_fixture_mtime "$file"
  output="$TMP_ROOT/heading-order.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 1 ] || fail "swapped headings exited $RUN_STATUS instead of 1"
  assert_only_finding "$output" heading-order
  pass "fm-briefing-lint: rejects template headings out of order"
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
  printf '\nSEALED 04:05 +07 2026-08-25\n' >> "$file"
  touch -t 202608251200 "$file"
  output="$TMP_ROOT/sealed-mtime.out"
  run_linter "$file" "$output"
  [ "$RUN_STATUS" -eq 0 ] || fail "sealed later mtime exited $RUN_STATUS: $(cat "$output")"
  [ "$(cat "$output")" = OK ] || fail "sealed later-mtime fixture did not print OK"
  pass "fm-briefing-lint: permits a sealed file to have a later mtime"
}

test_clean_file_is_accepted
test_wrong_weekday_is_rejected
test_every_clock_time_requires_the_offset
test_credential_patterns_are_rejected
test_missing_last_updated_stamp_is_rejected
test_every_template_heading_is_required
test_unexpected_h2_heading_is_rejected
test_h3_subsections_are_not_flagged
test_duplicate_template_heading_is_rejected
test_template_headings_must_keep_their_order
test_bare_pr_reference_requires_matching_https_url
test_pr_reference_with_matching_https_url_is_accepted
test_exactly_one_h1_is_required
test_mtime_date_must_match_filename_without_sealed_marker
test_sealed_marker_allows_later_mtime
