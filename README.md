<h1 align="center">ripr</h1>

<p align="center">
  Diff-driven mutation testing for Ruby that highlights untested code, missing test inputs, and gaps in assertions.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/ripr"><img alt="RubyGems version" src="https://img.shields.io/gem/v/ripr?label=RubyGems"></a>
  <a href="https://github.com/ydah/ripr/actions/workflows/main.yml"><img alt="Ruby CI" src="https://github.com/ydah/ripr/actions/workflows/main.yml/badge.svg?branch=main"></a>
  <a href="#installation"><img alt="CRuby 3.3 and later" src="https://img.shields.io/badge/CRuby-3.3%2B-CC342D"></a>
  <a href="LICENSE.txt"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#reading-the-results">Results</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#ci">CI</a>
</p>

## Installation

ripr requires CRuby 3.3 or later on Linux or macOS and a Minitest or RSpec suite. Add ripr to your project's Gemfile.

```ruby
gem "ripr", "~> 0.1", group: :test, require: false
```

To install from GitHub, use `gem "ripr", git: "https://github.com/ydah/ripr.git", group: :test, require: false`.

## Quick start

Run a full mutation test from your project's root.

```sh
bundle install
bundle exec ripr --full
```

For everyday changes, run against a Git reference.

```sh
bundle exec ripr --since origin/main
```

`--since` selects mutations on lines changed since the merge base, including staged, unstaged, and untracked source changes. Use `--scope method` to include every mutation in a touched method. The score and quality gates apply to the selected mutations.

## Reading the results

ripr observes an unmodified test run, then runs relevant tests against each mutation. Each gap tells you what to investigate next.

| Result | What happened | What to try |
| --- | --- | --- |
| `not_reached` | No test ran the expression. | Exercise the method and branch. |
| `not_infected` | Tests ran the expression, and the mutation left its value unchanged for the observed inputs. | Add a boundary case or another input. |
| `not_detected` | The mutation was exercised and tests still passed. | Check whether the changed value reaches an assertion. |

Ages 20 and 10 produce the same results for `age >= 18` and `age > 18`. The text report shows the inputs that reached the comparison.

```text
not infected lib/sample.rb:5:5 "age >= 18" → "age > 18" id=9c572228cf
  observed: [[20,18],[10,18]]
```

Add age 18 to exercise the boundary.

When ripr cannot safely compare values during the baseline, it keeps the affected tests in the mutation run. Use `--verify-not-infected` to run the relevant tests against mutations classified as `not_infected`.

### Reports

The default report is text. Write an HTML report and its `mutation.json` data to `.ripr/report/` with `bundle exec ripr --reporter html`. The interactive viewer requires network access, and the static table works offline.

For tools and coding agents, use `bundle exec ripr --since origin/main --reporter agent` to emit [JSON with a suggested action for each gap](schema/agent-v1.json). Keep `agent` as the only stdout reporter when piping JSON. Use `bundle exec ripr --only MUTANT_ID` to rerun a single mutation.

Install the [bundled agent skill](skills/mutation-test-loop/SKILL.md) with `bundle exec ripr init-skill`. The default destination is `.claude/skills/mutation-test-loop`. Use `--dir` to choose another directory.

### Equivalent mutations

Use `bundle exec ripr accept MUTANT_ID --reason "Why the documented behavior makes this equivalent"` to accept a mutation. Track `ripr.accepted.yml` in your project. A change to the method invalidates its acceptance.

For source-level exclusions, use `ripr:disable-line` or `ripr:disable-next-line` with an operator and a reason.

```ruby
value >= limit # ripr:disable-line comparison -- The specification excludes the boundary
```

## Configuration

Run `bundle exec ripr init` to generate `.ripr.yml`. ripr looks for source under `lib/` by default and detects Minitest or RSpec. Set the framework and test glob explicitly when needed.

```yaml
include: [lib/**/*.rb]
exclude: [lib/**/version.rb]
framework: rspec
tests: "spec/**/*_spec.rb"
jobs: auto
```

Use `bundle exec ripr --help` for CLI options and `bundle exec ripr list operators` for available mutations. CLI flags override file settings. Ignore `.ripr/` in Git. Use `--full` to bypass cached results, especially after changing external test data or environment variables.

## CI

For a pull request workflow on GitHub Actions, fetch history for the merge base and install your project's bundle.

```yaml
steps:
  - uses: actions/checkout@v6
    with:
      fetch-depth: 0
  - uses: ruby/setup-ruby@v1
    with:
      ruby-version: "3.3"
      bundler-cache: true
  - run: bundle exec ripr --since origin/main --reporter text --reporter github
```

The `github` reporter adds annotations for surviving mutations. The [composite action](action.yml) also caches `.ripr/`. After establishing a baseline, add `--fail-on-survived` or `--threshold 80` to enforce a quality gate.

| Exit code | Meaning |
| --- | --- |
| 0 | Run completed and any requested quality gates passed. |
| 1 | Invalid arguments or configuration. |
| 2 | A quality gate failed. |
| 3 | Internal execution error. |
| 4 | Baseline tests failed. |

Timeouts count as detected mutations. Errors remain in the score denominator. Accepted, static, and invalid mutations are excluded.

## Scope and limitations

ripr targets pure Ruby libraries. Start it before loading the source under test. It uses `fork` and CRuby's instruction-sequence loader. Use `RIPR_LOADER=require` for the alternate loader, which rejects wrapped target `load` calls. Configure bootsnap before ripr installs its hook.

Mutation sites are inside ordinary method definitions. Class-body and top-level expressions, `define_method` blocks, singleton receivers other than `self`, and detached heredoc interpolation are excluded. Operands of `defined?` stay intact. ripr instruments source in memory.

Use deterministic, independent tests. Shared state, time, and thread ordering can invalidate cached observations. If a mutation site runs outside a tracked test, ripr conservatively selects all tests. Mutations cannot change effects already computed while loading. Ractor and complete Rails integration are outside the supported scope.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop --cache false
gem build ripr.gemspec
```

Run `bundle exec ruby script/self_mutate.rb` to mutation-test ripr's Core. The project is licensed under the [MIT License](LICENSE.txt).
