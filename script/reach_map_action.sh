#!/usr/bin/env bash
set -euo pipefail

if [[ "$RIPR_ACTION_REACH_MAP_ENV" == *$'\n'* ]]; then
  echo 'reach-map-env requires a space-separated list of environment variable names' >&2
  exit 1
fi
read -r -a names <<< "PATH HOME LANG LC_ALL LC_CTYPE TZ CI GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG RBENV_ROOT RBENV_VERSION GITHUB_WORKSPACE $RIPR_ACTION_REACH_MAP_ENV"
workload=(env -i)
for name in "${names[@]}"; do
  if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ || "$name" =~ ^(GH|GITHUB)(_ENTERPRISE)?_TOKEN$ ||
        "$name" =~ ^ACTIONS_(RUNTIME|ID_TOKEN_REQUEST)_TOKEN$ || "$name" =~ ^GITHUB_(ENV|OUTPUT|PATH|STATE|STEP_SUMMARY)$ ]]; then
    echo 'reach-map-env requires valid environment variable names and excludes GitHub tokens and workflow command files' >&2
    exit 1
  fi
  if [[ ${!name+x} == x ]]; then workload+=("$name=${!name}"); fi
done

artifact_name() {
  local prefix workload_identity identity
  prefix=$(git rev-parse --show-prefix) || return 1
  workload_identity=$("${workload[@]}" ruby -rdigest -e \
    'print RUBY_DESCRIPTION, ":", Digest::SHA256.hexdigest(Marshal.dump(ENV.to_a.sort))') || return 1
  identity=$(printf '%s\0%s\0' "$prefix" "$workload_identity" | git hash-object --stdin) || return 1
  printf 'ripr-reach-map-%s\n' "$identity"
}

find_map() {
  local branch base artifact server runs run directory
  branch=${RIPR_ACTION_BASE_BRANCH:-$RIPR_ACTION_DEFAULT_BRANCH}
  base=$(git merge-base -- "$RIPR_ACTION_SINCE" HEAD) || return 1
  artifact=$(artifact_name) || return 1
  server=${GITHUB_SERVER_URL:-https://github.com}
  export GH_HOST=${server#https://}
  export GH_ENTERPRISE_TOKEN=$GH_TOKEN
  runs=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/$RIPR_ACTION_REACH_MAP_WORKFLOW/runs" \
    -f branch="$branch" -f head_sha="$base" -f status=success -F per_page=10 |
    jq -r --arg branch "$branch" --arg base "$base" --arg repo "$GITHUB_REPOSITORY" '
      .workflow_runs[]
      | select(.head_sha == $base and .head_branch == $branch and .head_repository.full_name == $repo)
      | select(.status == "completed" and .conclusion == "success")
      | select(.event == "push" or .event == "schedule" or .event == "workflow_dispatch")
      | .id
    ') || return 1
  while IFS= read -r run; do
    [[ "$run" =~ ^[0-9]+$ ]] || continue
    directory=$(mktemp -d "$RUNNER_TEMP/ripr-reach-map.XXXXXX") || return 1
    if gh run download "$run" --repo "$GITHUB_REPOSITORY" --name "$artifact" --dir "$directory" >/dev/null &&
       [[ -f "$directory/reach-map.json" && ! -L "$directory/reach-map.json" ]]; then
      printf '%s\n' "$directory/reach-map.json"
      return 0
    fi
  done <<< "$runs"
  return 1
}

case "$RIPR_ACTION_REACH_MAP" in
  record)
    if [[ "$GITHUB_REF" != "refs/heads/$RIPR_ACTION_DEFAULT_BRANCH" || "$GITHUB_SHA" != "$(git rev-parse --verify HEAD)" ||
          ! "$GITHUB_EVENT_NAME" =~ ^(push|schedule|workflow_dispatch)$ ]]; then
      echo 'reach-map recording requires a default-branch checkout from a push, schedule, or workflow_dispatch run' >&2
      exit 1
    fi
    name=$(artifact_name)
    "${workload[@]}" bundle exec ripr reach-map
    directory=$(mktemp -d "$RUNNER_TEMP/ripr-reach-map.XXXXXX")
    cp .ripr/reach-map.json "$directory/reach-map.json"
    printf 'artifact-name=%s\nartifact-path=%s\n' "$name" "$directory/reach-map.json" >> "$GITHUB_OUTPUT"
    ;;
  use)
    if [[ "$GITHUB_EVENT_NAME" == pull_request_target ]]; then
      echo 'reach-map use requires a pull_request workflow for untrusted changes' >&2
      exit 1
    fi
    if [[ -z "$RIPR_ACTION_SINCE" || ! "$RIPR_ACTION_REACH_MAP_WORKFLOW" =~ ^[a-zA-Z0-9_.-]+\.ya?ml$ ]]; then
      echo 'reach-map use requires since and a reach-map-workflow filename' >&2
      exit 1
    fi
    args=(--reporter text --reporter github --since "$RIPR_ACTION_SINCE")
    if [[ "$RIPR_ACTION_FAIL" == true ]]; then args+=(--fail-on-survived); fi
    if [[ -n "$RIPR_ACTION_THRESHOLD" ]]; then args+=(--threshold "$RIPR_ACTION_THRESHOLD"); fi
    if map=$(find_map 2>/dev/null); then
      args+=(--reach-map "$map")
    else
      echo 'ripr: No trusted reach map for the merge base. Running the ordinary diff baseline.' >&2
    fi
    exec "${workload[@]}" bundle exec ripr "${args[@]}"
    ;;
  *)
    echo 'reach-map mode must be record or use' >&2
    exit 1
    ;;
esac
