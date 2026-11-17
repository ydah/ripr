# ripr

ripr is a diff-driven mutation test runner for Ruby. It observes values during a baseline run, then runs relevant tests against each mutation to distinguish missing execution, missing inputs, and missing assertions.

| Result | What happened | Next step |
| --- | --- | --- |
| `not_reached` | No test executed the expression. | Exercise the method and branch. |
| `not_infected` | Tests reached it, but the mutation never changed its value. | Add a boundary or another input. |
| `not_detected` | The mutation was exercised and tests still passed. | Check propagation and strengthen assertions. |

Tests of `age >= 18` using only ages 20 and 10 cannot distinguish it from `age > 18`. ripr reports `not_infected` with observed operands `[[20, 18], [10, 18]]`. Age 18 exposes the missing boundary.

## Try this checkout

Requires CRuby 3.3 or later on Linux or macOS. Prism is the only runtime gem dependency; the target project supplies Minitest or RSpec.

```sh
bundle install
bundle exec ripr test/fixtures/projects/minitest_basic --reporter agent
bundle exec rake test
```

Before the first RubyGems release, add a local checkout to another project's Gemfile:

```ruby
group :test do
  gem "ripr", path: "/path/to/ripr", require: false
end
```

Run from the target project root:

```sh
bundle exec ripr init
bundle exec ripr --since origin/main
bundle exec ripr --full --fail-on-survived --threshold 80
bundle exec ripr --framework rspec --tests 'spec/**/*_spec.rb' -j 4
```

`--since` compares the merge base with staged, unstaged, and untracked source changes. Scores and quality gates cover selected mutations. `--scope node` is the default; `--scope method` selects all mutations in a touched method. `--full` selects the entire target and disables reuse.

## Agent test loop

```sh
bundle exec ripr init-skill
bundle exec ripr --since origin/main --reporter agent
bundle exec ripr --only MUTANT_ID --reporter agent
bundle exec ripr accept MUTANT_ID --reason "Why the documented behavior makes this equivalent"
```

The [bundled skill](skills/mutation-test-loop/SKILL.md) guides test changes using the classification. `init-skill` copies it to `.claude/skills/mutation-test-loop`; use `--dir` for another directory. Modified copies require `--force` to overwrite.

Acceptances go into `ripr.accepted.yml`, which belongs in version control. Method changes invalidate acceptances and produce warnings. Inline exclusions are also supported:

```ruby
value >= limit # ripr:disable-line comparison -- The specification excludes the boundary
# ripr:disable-next-line integer_literal -- Protocol constant
code = 42
```

## Reports and configuration

```sh
bundle exec ripr --reporter json --reporter html
bundle exec ripr --reporter text --reporter github
bundle exec ripr list operators
bundle exec ripr list mutants
bundle exec ripr --dry-run --operators comparison,arithmetic
```

`text` is the default reporter. `agent` writes the [versioned JSON protocol](schema/agent-v1.json) to stdout; loading diagnostics go to stderr. Use one stdout reporter when piping JSON to another program. File reports go to `.ripr/report/`, configurable with `--report-dir`.

`mutation.json` follows mutation-testing-elements schema v2. The interactive HTML viewer needs network access. A static table is available offline.

`.ripr.yml` supports include/exclude globs, framework, tests, scope, jobs, operators, arid callees, thresholds, timeout, and samples. Unknown keys are errors. CLI settings override the file, then defaults; nested timeout and threshold settings merge.

```yaml
include: [lib/**/*.rb]
exclude: [lib/**/version.rb]
framework: auto
jobs: auto
operators: default
thresholds: {high: 80, low: 60, break: null}
timeout: {factor: 2.0, base_ms: 1000}
samples: true
```

The eight default operators cover comparisons, arithmetic, integer and boolean literals, condition negation, boolean connectors, return nil, and statement removal. `return_nil` preserves evaluation and side effects, then discards the returned value. `--no-samples` disables operand observations.

Ignore the `.ripr/` cache directory in Git. Source edits invalidate reuse, while independent test-only edits can reuse part of the baseline. `--only` reruns selected mutations. `--verify-not-infected` runs tests to check that classification.

| Exit | Meaning |
| --- | --- |
| 0 | Completed; requested quality gates passed. |
| 1 | Invalid arguments or configuration. |
| 2 | Surviving mutations or score failed a gate. |
| 3 | Internal execution error. |
| 4 | Baseline tests failed. |

Timeouts count as detected mutations. Errors remain in the score denominator. Accepted, static, and invalid mutations are excluded.

## CI

Install Ruby and the project's bundle, and fetch history for `merge-base`:

```yaml
steps:
  - uses: actions/checkout@v6
    with:
      fetch-depth: 0
  - uses: ruby/setup-ruby@v1
    with:
      bundler-cache: true
  - run: bundle exec ripr --since origin/main --reporter text --reporter github
```

Add `--fail-on-survived` after establishing a baseline. The [composite action](action.yml) caches `.ripr/` and adds annotations.

## Scope and limitations

v0.1 targets pure Ruby libraries. It requires `fork` and CRuby's instruction-sequence loader. Start ripr before requiring the source you want to mutate. `RIPR_LOADER=require` selects an alternate loader that explicitly rejects wrapped target `load` calls. bootsnap is supported when configured before ripr installs its hook.

Class-body and top-level expressions are static and excluded. `define_method` blocks, non-`self` singleton receivers, and detached heredoc interpolation sites are excluded with diagnostics. Unevaluated `defined?` operands are left intact. Source files are never rewritten.

Tests should be deterministic and independent. Shared test state, time, unseeded randomness, and thread ordering can invalidate cached observations; use `--full` when investigating. Activity outside a tracked test conservatively selects all tests and adds a report note: mutation switching cannot change effects already computed during loading. Ractor, Windows, JRuby, TruffleRuby, and complete Rails integration are outside this release's scope. Code depending on exact call-stack depth may require exclusion.

## Development

```sh
bundle exec rake test
bundle exec rubocop --cache false
gem build ripr.gemspec
```

Run `bundle exec ruby script/self_mutate.rb` to mutation-test ripr's Core.

Licensed under the [MIT License](LICENSE.txt).
