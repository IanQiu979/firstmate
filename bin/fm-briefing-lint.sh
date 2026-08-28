#!/usr/bin/env bash
# fm-briefing-lint.sh - validate one daily briefing against its file contract.
#
# Usage:
#   bin/fm-briefing-lint.sh <daily-briefing.md>
#
# Prints one `<check-name>: <detail>` line per violation, or `OK` when clean.
# Exit status is 0 for a clean file, 1 for contract violations, and 2 for an
# invalid invocation or an unreadable input file.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

BRIEFING=$1
if [ ! -f "$BRIEFING" ] || [ ! -r "$BRIEFING" ]; then
  printf 'fm-briefing-lint: input is not a readable file: %s\n' "$BRIEFING" >&2
  exit 2
fi

VIOLATIONS=0

report() {
  printf '%s: %s\n' "$1" "$2"
  VIOLATIONS=$((VIOLATIONS + 1))
}

clock_minutes() {
  local stamp=$1 hour minute
  hour=${stamp%:*}
  minute=${stamp#*:}
  printf '%s\n' "$((10#$hour * 60 + 10#$minute))"
}

weekday_for_date() {
  local value=$1 result
  result=$(date -j -f '%Y-%m-%d' "$value" '+%A' 2>/dev/null) && {
    printf '%s\n' "$result"
    return 0
  }
  result=$(date -d "$value" '+%A' 2>/dev/null) && {
    printf '%s\n' "$result"
    return 0
  }
  return 1
}

mtime_date() {
  local path=$1 result
  result=$(stat -f '%Sm' -t '%Y-%m-%d' "$path" 2>/dev/null) || result=
  if [[ $result =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%s\n' "$result"
    return 0
  fi
  result=$(stat -c '%y' "$path" 2>/dev/null) || return 1
  printf '%.10s\n' "$result"
}

# The title is the schema owner for both values, so compare the weekday and
# date captured from the same h1 rather than inferring either from the path.
heading_found=0
heading_weekday=
heading_date=
heading_re='^# Daily Briefing — ([A-Za-z]+) ([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]*$'
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $heading_re ]]; then
    heading_found=1
    heading_weekday=${BASH_REMATCH[1]}
    heading_date=${BASH_REMATCH[2]}
    break
  fi
done < "$BRIEFING"

if [ "$heading_found" -eq 0 ]; then
  report weekday 'daily-briefing h1 is missing or malformed'
else
  expected_weekday=$(weekday_for_date "$heading_date") || expected_weekday=
  if [ -z "$expected_weekday" ]; then
    report weekday "heading date is invalid: $heading_date"
  elif [ "$heading_weekday" != "$expected_weekday" ]; then
    report weekday "$heading_date is $expected_weekday, not $heading_weekday"
  fi
fi

# Read stamped sections once for ordering, liveness, and header freshness.
section_re='^## (([01][0-9]|2[0-3]):[0-5][0-9])[[:space:]]+\+07[[:space:]]+—[[:space:]]+.+$'
distinct_sections=0
seen_sections='|'
previous_stamp=
previous_minutes=
last_section_stamp=
last_section_minutes=
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  if [[ $line =~ $section_re ]]; then
    stamp=${BASH_REMATCH[1]}
    minutes=$(clock_minutes "$stamp")
    case "$seen_sections" in
      *"|$stamp|"*) ;;
      *)
        distinct_sections=$((distinct_sections + 1))
        seen_sections="${seen_sections}${stamp}|"
        ;;
    esac
    if [ -n "$previous_minutes" ] && [ "$minutes" -le "$previous_minutes" ]; then
      report section-order "line $line_number stamp $stamp is not later than $previous_stamp"
    fi
    previous_stamp=$stamp
    previous_minutes=$minutes
    last_section_stamp=$stamp
    last_section_minutes=$minutes
  fi
done < "$BRIEFING"

if grep -Eq '^\*\*Status:[[:space:]]*live\*\*[[:space:]]*$' "$BRIEFING"; then
  if [ "$distinct_sections" -lt 3 ]; then
    report live-status "live requires at least 3 distinct stamped sections; found $distinct_sections"
  fi
fi

last_updated_stamp=
last_updated_re='^\*\*Last updated:[[:space:]]*(([01][0-9]|2[0-3]):[0-5][0-9])[[:space:]]+\+07\*\*'
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $last_updated_re ]]; then
    last_updated_stamp=${BASH_REMATCH[1]}
    break
  fi
done < "$BRIEFING"
if [ -z "$last_updated_stamp" ]; then
  report last-updated 'header is missing a valid Last updated: HH:MM +07 stamp'
elif [ -n "$last_section_minutes" ]; then
  last_updated_minutes=$(clock_minutes "$last_updated_stamp")
  if [ "$last_updated_minutes" -lt "$last_section_minutes" ]; then
    report last-updated "$last_updated_stamp is earlier than last section $last_section_stamp"
  fi
fi

# A clock may use parenthetical punctuation, but every individual HH:MM token
# must be followed by its own +07 marker.
clock_re='([01][0-9]|2[0-3]):[0-5][0-9]'
offset_re='^[[:space:]]*(\([[:space:]]*)?\+07'
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  rest=$line
  while [[ $rest =~ $clock_re ]]; do
    stamp=${BASH_REMATCH[0]}
    after=${rest#*"$stamp"}
    if ! [[ $after =~ $offset_re ]]; then
      report timezone "line $line_number clock $stamp has no +07 offset"
    fi
    rest=$after
  done
done < "$BRIEFING"

credential_re='sk-ant-[A-Za-z0-9_-]{8,}|[A-Fa-f0-9]{64}|ghp_|github_pat_|xox[baprs]-|AKIA|-----BEGIN'
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  if [[ $line =~ $credential_re ]]; then
    report credentials "credential-shaped string at line $line_number"
  fi
done < "$BRIEFING"

for required_heading in \
  'Open for the captain' \
  'Shipped today' \
  'Broke / went wrong' \
  'Still open' \
  'Log' \
  'Reference'; do
  if ! grep -Fqx "## $required_heading" "$BRIEFING"; then
    report required-heading "missing ## $required_heading"
  fi
done

pr_numbers=$(grep -Eo '#[0-9]+' "$BRIEFING" 2>/dev/null | tr -d '#' | LC_ALL=C sort -nu || true)
while IFS= read -r pr_number; do
  [ -n "$pr_number" ] || continue
  if ! grep -Eq "https://[^[:space:]<>()]+/(pull|pulls|pull-requests)/${pr_number}([^0-9]|$)" "$BRIEFING"; then
    report pr-url "PR #$pr_number has no matching full https:// URL"
  fi
done <<< "$pr_numbers"

h1_count=$(grep -c '^# ' "$BRIEFING" 2>/dev/null || true)
if [ "$h1_count" -ne 1 ]; then
  report h1-count "expected exactly 1 h1; found $h1_count"
fi

filename=${BRIEFING##*/}
if [[ $filename =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$ ]]; then
  filename_date=${BASH_REMATCH[1]}
  actual_mtime_date=$(mtime_date "$BRIEFING") || actual_mtime_date=
  if [ -z "$actual_mtime_date" ]; then
    report mtime-date 'could not read file modification date'
  elif [ "$actual_mtime_date" != "$filename_date" ] && ! grep -q 'SEALED' "$BRIEFING"; then
    report mtime-date "mtime date $actual_mtime_date does not match filename date $filename_date and no SEALED marker is present"
  fi
else
  report mtime-date "filename does not match YYYY-MM-DD.md: $filename"
fi

if [ "$VIOLATIONS" -eq 0 ]; then
  printf 'OK\n'
  exit 0
fi
exit 1
