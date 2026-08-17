#!/usr/bin/env bash
# fm-lint-workflows.sh - owner of firstmate's GitHub workflow YAML validation.
#
# Parses every .github/workflows/*.{yml,yaml} so a malformed workflow, including
# a self-broken ci.yml, fails in the local and no-mistakes lint lane before
# merge. A broken ci.yml cannot report its own breakage, so this check must not
# live only as a step inside that workflow. bin/fm-lint.sh invokes this owner
# on its default (no explicit-path) path, which CI and commands.lint both use.
#
# Usage:
#   fm-lint-workflows.sh                 lint workflows under this repo
#   fm-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   fm-lint-workflows.sh <path>...       lint explicit workflow files
#   fm-lint-workflows.sh --help
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

fm_lint_workflows_usage() {
  sed -n '2,15{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'fm-lint-workflows.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

if ! command -v ruby >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: ruby is required to parse GitHub workflow YAML.\n' >&2
  exit 127
fi

set +e
ruby - "${FILES[@]}" <<'RUBY'
require 'psych'

status = 0
ARGV.each do |path|
  begin
    doc = Psych.parse_file(path)
    root = doc && doc.root
    unless root.is_a?(Psych::Nodes::Mapping)
      $stderr.puts "fm-lint-workflows.sh: #{path}: workflow YAML root must be a mapping"
      status = 1
      next
    end
  rescue Psych::SyntaxError => e
    problem = e.respond_to?(:problem) && e.problem ? e.problem : e.message
    line = e.respond_to?(:line) ? e.line : '?'
    column = e.respond_to?(:column) ? e.column : '?'
    $stderr.puts "fm-lint-workflows.sh: invalid YAML in #{path}: #{problem} at line #{line} column #{column}"
    status = 1
  rescue StandardError => e
    $stderr.puts "fm-lint-workflows.sh: could not parse #{path}: #{e.message}"
    status = 1
  end
end
exit status
RUBY
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

printf 'fm-lint-workflows.sh: %s workflow files valid\n' "${#FILES[@]}"
exit 0
