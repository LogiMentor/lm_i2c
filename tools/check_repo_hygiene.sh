#!/usr/bin/env bash
# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
shopt -s nocasematch

mode=Full
commit_message_file=
revision_range=HEAD
failures=0
temp_root=

usage() {
  printf '%s\n' \
    "Usage:" \
    "  check_repo_hygiene.sh [--full|--staged|--tracked-paths]" \
    "  check_repo_hygiene.sh --commit-message-file <path>" \
    "  check_repo_hygiene.sh --history [--revision-range <range>]" >&2
}

while (($# > 0)); do
  case "$1" in
    --full)
      mode=Full
      shift
      ;;
    --staged)
      mode=Staged
      shift
      ;;
    --tracked-paths)
      mode=Tracked
      shift
      ;;
    --commit-message-file)
      if (($# < 2)); then
        usage
        exit 2
      fi
      mode=CommitMessage
      commit_message_file=$2
      shift 2
      ;;
    --history)
      mode=History
      shift
      ;;
    --revision-range)
      if (($# < 2)); then
        usage
        exit 2
      fi
      revision_range=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/lm_i2c-hygiene.XXXXXX")

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

path_pattern='(^|/)(reference|private|AGENTS\.md)(/|$)|(^|/)(#[^/]+#|[^/]+~|[^/]+\.(swp|swo|tmp|temp|bak|orig|rej)|~\$[^/]+|\.DS_Store)$|\.(ghw|vcd|fst|wlf|vpd|fsdb|jou|log|exe|o)$|(^|/)(build|dist|out|work|work-ghdl[^/]*|coverage|synth)(/|$)' # hygiene-pattern-definition
absolute_path_pattern='([[:alpha:]]:[\\/](Users|Documents and Settings)[\\/]|/(home|Users)/[^/[:space:]]+/|file:///([[:alpha:]]:|home/|Users/))' # hygiene-pattern-definition
legacy_identifier_pattern='(^|[^[:alnum:]_])ces_[[:alnum:]_]*' # hygiene-pattern-definition
legacy_organization_pattern='Campera[[:space:]]+Electronic[[:space:]]+Systems([[:space:]]+Srl)?|([[:alnum:]-]+\.)?campera-es\.com' # hygiene-pattern-definition
trailer_pattern='^[[:space:]]*(co-authored-by|generated-by|assisted-by)[[:space:]]*:' # hygiene-pattern-definition
attribution_pattern='(^|[^[:alnum:]_])((generated|created|written|authored|assisted|produced)[[:space:]]+(by|with|using)[[:space:]]+(an?[[:space:]]+)?(ai|llm|language[ -]model|chatgpt|codex|copilot|claude|gemini)|(ai|llm|language[ -]model)[ -](generated|assisted|authored))([^[:alnum:]_]|$)' # hygiene-pattern-definition
prompt_pattern='(^|[^[:alnum:]_])((system[[:space:]]+prompt|developer[[:space:]]+message|user[[:space:]]+prompt|task[[:space:]]+instructions)[[:space:]]*:|begin[[:space:]]+prompt|end[[:space:]]+prompt|my[[:space:]]+request[[:space:]]+for[[:space:]]+codex)([^[:alnum:]_]|$)' # hygiene-pattern-definition

report_failure() {
  printf '[HYG] %s: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

is_text_path() {
  lower=${1,,}
  case "$lower" in
    *.cfg|*.conf|*.ini|*.json|*.md|*.ps1|*.sh|*.tcl|*.toml|*.txt|*.vhd|*.vhdl|*.yaml|*.yml)
      return 0
      ;;
  esac
  case "${lower##*/}" in
    .editorconfig|.gitattributes|.gitignore|license|notice)
      return 0
      ;;
  esac
  return 1
}

check_path() {
  display_path=${1//\\//}
  if [[ "$display_path" =~ $path_pattern ]]; then
    report_failure "$display_path" "blocked public path"
  fi
}

check_restricted_line() {
  line=$1
  display_path=$2
  line_number=$3

  if [[ "$display_path" == *"tools/check_repo_hygiene.sh"* ||
        "$display_path" == *"tools/check_repo_hygiene.ps1"* ||
        "$line" == *"hygiene-pattern-definition"* ]]; then
    return
  fi
  if [[ "$line" =~ $absolute_path_pattern ]]; then
    report_failure "$display_path:$line_number" "absolute local user path"
  fi
  if [[ "$line" =~ $legacy_identifier_pattern ]]; then
    report_failure "$display_path:$line_number" "legacy public identifier"
  fi
  if [[ "$line" =~ $legacy_organization_pattern ]]; then
    report_failure "$display_path:$line_number" "legacy organization marker"
  fi
  if [[ "$line" =~ $trailer_pattern ]]; then
    report_failure "$display_path:$line_number" "prohibited authorship trailer"
  fi
  if [[ "$line" =~ $attribution_pattern ]]; then
    report_failure "$display_path:$line_number" "prohibited attribution marker"
  fi
  if [[ "$line" =~ $prompt_pattern ]]; then
    report_failure "$display_path:$line_number" "prompt or task transcript"
  fi
}

check_text_file() {
  source_path=$1
  display_path=$2
  line_number=0

  if ! iconv -f UTF-8 -t UTF-8 "$source_path" >/dev/null 2>&1; then
    report_failure "$display_path" "text is not valid UTF-8"
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ "$line" == *$'\r'* ]]; then
      report_failure "$display_path:$line_number" "carriage return"
      line=${line//$'\r'/}
    fi
    if [[ "$line" =~ [[:blank:]]$ ]]; then
      if [[ "$display_path" != *.md || ! "$line" =~ [^[:blank:]][[:space:]][[:space:]]$ ]]; then
        report_failure "$display_path:$line_number" "trailing whitespace"
      fi
    fi
    if [[ "$line" =~ ^(<<<<<<<|=======|\>\>\>\>\>\>\>)([[:space:]]|$) ]]; then
      report_failure "$display_path:$line_number" "merge-conflict marker"
    fi
    check_restricted_line "$line" "$display_path" "$line_number"
  done <"$source_path"

  if [[ -s "$source_path" ]]; then
    final_byte=$(tail -c 1 "$source_path" | od -An -tu1 | tr -d '[:space:]')
    if [[ "$final_byte" != "10" ]]; then
      report_failure "$display_path" "missing final newline"
    fi
  fi
}

check_working_path() {
  path=$1
  check_path "$path"
  if is_text_path "$path"; then
    check_text_file "$repo_root/$path" "$path"
  fi
}

check_staged_path() {
  path=$1
  check_path "$path"
  if is_text_path "$path"; then
    blob_file="$temp_root/staged-blob"
    if git -C "$repo_root" show --no-textconv ":$path" >"$blob_file"; then
      check_text_file "$blob_file" "$path"
    else
      report_failure "$path" "unable to read staged content"
    fi
  fi
}

check_revision_tree() {
  revision=$1
  path_list="$temp_root/history-paths"
  git -C "$repo_root" ls-tree -r -z --name-only "$revision" >"$path_list"
  while IFS= read -r -d '' path; do
    check_path "$path"
    if is_text_path "$path"; then
      blob_file="$temp_root/history-blob"
      if git -C "$repo_root" show --no-textconv "$revision:$path" >"$blob_file"; then
        check_text_file "$blob_file" "$revision:$path"
      else
        report_failure "$revision:$path" "unable to read historical content"
      fi
    fi
  done <"$path_list"
}

case "$mode" in
  Full)
    path_list="$temp_root/full-paths"
    git -C "$repo_root" ls-files --cached --others --exclude-standard -z \
      >"$path_list"
    while IFS= read -r -d '' path; do
      if [[ -f "$repo_root/$path" ]]; then
        check_working_path "$path"
      fi
    done <"$path_list"
    ;;
  Staged)
    path_list="$temp_root/staged-paths"
    git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR -z \
      >"$path_list"
    while IFS= read -r -d '' path; do
      check_staged_path "$path"
    done <"$path_list"
    ;;
  Tracked)
    path_list="$temp_root/tracked-paths"
    git -C "$repo_root" ls-files -z >"$path_list"
    while IFS= read -r -d '' path; do
      check_path "$path"
    done <"$path_list"
    ;;
  CommitMessage)
    if [[ ! -f "$commit_message_file" ]]; then
      printf '%s\n' "Commit-message file is required and must exist." >&2
      exit 2
    fi
    check_text_file "$commit_message_file" "$commit_message_file"
    ;;
  History)
    while IFS= read -r revision; do
      message_file="$temp_root/history-message"
      git -C "$repo_root" show -s --format=%B "$revision" >"$message_file"
      check_text_file "$message_file" "$revision:message"
      check_revision_tree "$revision"
    done < <(git -C "$repo_root" rev-list "$revision_range")
    ;;
esac

if ((failures != 0)); then
  printf 'Repository hygiene failed with %s violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'Repository hygiene passed (%s mode).\n' "$mode"
