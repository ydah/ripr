#!/usr/bin/env bash
set -euo pipefail

mode=${1:?expected plan, shard, or merge}
workspace=${GITHUB_WORKSPACE:?}
scratch=${RUNNER_TEMP:?}/ripr-shards
fixture="$workspace/test/fixtures/projects/minitest_basic"
mkdir -p "$scratch"
mkdir "$scratch/project"
cd "$scratch/project"
cp -R "$fixture/lib" "$fixture/test" .
printf '.ripr/\n' > .gitignore
git init -q -b main
git add .
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  git -c user.name=Ripr -c user.email=ripr@example.com -c commit.gpgsign=false commit -qm 'Shard fixture'

ruby_bin=$(ruby -rrbconfig -e 'print File.dirname(RbConfig.ruby)')
ripr() {
  env -i "PATH=$ruby_bin:/usr/bin:/bin" "HOME=$HOME" "BUNDLE_GEMFILE=$workspace/Gemfile" LANG=C LC_ALL=C \
    "$ruby_bin/bundle" exec "$ruby_bin/ruby" "$workspace/exe/ripr" "$@" --jobs 1 --no-samples
}

plan="$scratch/plan/shard-plan.json"
case "$mode" in
  plan)
    ripr shard-plan 2 --shard-plan "$plan"
    jq -e '.report.run.metrics.baseline_tests_run == 2 and (.shards | length == 2)' "$plan"
    ;;
  shard)
    index=${2:?expected shard index}
    ripr --shard "$index/2" --shard-plan "$plan" --report-dir "$scratch/result" --reporter agent > "$scratch/shard-agent.json"
    jq -e '.run.metrics.baseline_tests_run == 0' "$scratch/shard-agent.json"
    jq -e --argjson index "$index" '.index == $index and .total == 2' "$scratch/result/shard.json"
    ;;
  merge)
    first="$scratch/shards/ripr-result-1/shard.json"
    second="$scratch/shards/ripr-result-2/shard.json"
    ripr merge --shard-plan "$plan" --report-dir .ripr/merged --reporter agent-v2 --reporter json "$first" "$second" > "$scratch/merged.json"
    jq -e '.run.metrics.baseline_tests_run == 2' "$scratch/merged.json"
    ripr --report-dir .ripr/reused --reporter agent > "$scratch/reused.json"
    jq -e --slurpfile plan "$plan" \
      '.run.metrics.baseline_tests_run == 0 and .run.metrics.reused == ($plan[0].shards | flatten | length)' "$scratch/reused.json"
    ripr --full --report-dir .ripr/reference --reporter agent-v2 --reporter json > "$scratch/reference.json"
    report_body() {
      jq -eS '{summary,gaps,methods,weak_tests} | del(.gaps[].covering_tests[].duration_ms)' "$1"
    }
    report_body "$scratch/merged.json" > "$scratch/merged.body.json"
    report_body "$scratch/reference.json" > "$scratch/reference.body.json"
    cmp "$scratch/merged.body.json" "$scratch/reference.body.json"
    jq -eS '.files | map_values(.mutants |= sort_by(.id))' .ripr/merged/mutation.json > "$scratch/merged.mte.json"
    jq -eS '.files | map_values(.mutants |= sort_by(.id))' .ripr/reference/mutation.json > "$scratch/reference.mte.json"
    cmp "$scratch/merged.mte.json" "$scratch/reference.mte.json"
    ;;
  *)
    exit 1
    ;;
esac
