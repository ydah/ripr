#!/usr/bin/env bash
set -euo pipefail

mode=${1:?expected record or use}
workspace=$GITHUB_WORKSPACE
scratch="$workspace/.ripr/transport"
fixture="$workspace/test/fixtures/projects/minitest_basic"
action="$workspace/script/reach_map_action.sh"
mkdir -p "$scratch/bin"
mkdir "$scratch/project"
cd "$scratch/project"
cp -R "$fixture/lib" "$fixture/test" .
sed '/assert Sample.adult?(20)/a\
    assert Sample.adult?(18)
' "$fixture/test/sample_test.rb" > test/sample_test.rb
printf '.ripr/\n' > .gitignore
printf 'operators: [comparison]\n' > .ripr.yml
git init -q -b main
git add -f .
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  git -c user.name=Ripr -c user.email=ripr@example.com -c commit.gpgsign=false commit -qm 'Reach map fixture'

export RIPR_SMOKE_GH
RIPR_SMOKE_GH=$(command -v gh)
ruby_bin=$(ruby -rrbconfig -e 'print File.dirname(RbConfig.ruby)')
export PATH="$scratch/bin:$ruby_bin:/usr/bin:/bin"
export BUNDLE_GEMFILE="$workspace/Gemfile" LANG=C LC_ALL=C
export RIPR_ACTION_REACH_MAP="$mode" RIPR_ACTION_REACH_MAP_ENV=RIPR_SMOKE_MODE RIPR_SMOKE_MODE=fixture
export RIPR_ACTION_DEFAULT_BRANCH=main RIPR_ACTION_BASE_BRANCH=main RIPR_ACTION_SINCE=main
export RIPR_ACTION_REACH_MAP_WORKFLOW=reach-map-transport.yml RIPR_ACTION_FAIL=true RIPR_ACTION_THRESHOLD=''
export GITHUB_SHA
GITHUB_SHA=$(git rev-parse HEAD)

if [[ "$mode" == record ]]; then
  GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=push bash "$action"
  exit
fi
test "$mode" = use

# Simulate discovery of a completed default-branch run, then download from this real run.
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == api ]]; then
  jq -n --arg sha "$GITHUB_SHA" --arg repo "$GITHUB_REPOSITORY" --arg id "$GITHUB_RUN_ID" \
    '{workflow_runs: [{id: ($id | tonumber), head_sha: $sha, head_branch: "main", head_repository: {full_name: $repo},
                      event: "push", status: "completed", conclusion: "success"}]}'
else
  test "$1 $2 $3" = "run download $GITHUB_RUN_ID"
  exec "$RIPR_SMOKE_GH" "$@"
fi
SH
chmod +x "$scratch/bin/gh"
ruby -pi -e 'sub("age >= 18", "18 <= age")' lib/sample.rb

run_check() {
  local expected=$1 report status=0
  report=$(GITHUB_EVENT_NAME=pull_request bash "$action" 2>&1) || status=$?
  printf '%s\n' "$report"
  test "$status" -eq 0
  grep -Fq "Baseline $expected tests" <<< "$report"
  grep -Fq 'Killed 1 · Survived 0' <<< "$report"
  if [[ "$expected" == 2 ]]; then
    grep -Fq 'No trusted reach map for the merge base' <<< "$report"
  fi
}

run_check 1
RIPR_SMOKE_MODE=changed run_check 2
