# Benchmark corpus

The corpus benchmarks one file per project with comparison mutations and one ripr worker. The Rails case boots Fizzy with its SQLite test databases and runs three upstream model test files.

| Project | Pinned revision | Mutated file | Tests |
| --- | --- | --- | --- |
| diff-lcs | [aca4bd7](https://github.com/halostatue/diff-lcs/tree/aca4bd72c80231e0646071ad533c65820a4ecc93) | `lib/diff/lcs/change.rb` | `spec/**/*_spec.rb` |
| tzinfo | [d5893c9](https://github.com/tzinfo/tzinfo/tree/d5893c99bbcd842af86023f02a84fac1659b3031) | `lib/tzinfo/timestamp.rb` | `test/tc_timestamp{,_with_offset}.rb` |
| hashdiff | [d6ac7e7](https://github.com/liufengyun/hashdiff/tree/d6ac7e74ee5b362e067e27312ec7545c7845ce45) | `lib/hashdiff/util.rb` | `spec/**/*_spec.rb` |
| Fizzy | [0ecbcce](https://github.com/basecamp/fizzy/tree/0ecbccecdd76fe8f1850da4c5233998dfd148ea6) | `app/models/assignment.rb` | `test/models/{assignment,card,comment}_test.rb` |

Each cold run clears ripr's cache and measures the complete file. The edited run appends a comment to one comparison line and measures `--since HEAD` with the cache from the preceding cold run. Five alternating pairs include CLI startup, planning, application boot, test execution, and reporting. Dependency installation and database setup happen before timing. The gem-only `disabled_overhead` metric is the ratio of inactive-instrumentation to plain test time, minus one, using five runs per mode.

## Local baseline

Ruby 4.0.10 on a shared Apple M4 Pro workstation running macOS 26.3. Times are medians with the observed range in seconds. The measured ripr revision was [`ee470d9`](https://github.com/ydah/ripr/commit/ee470d9730715323718042dd1258cb7e65060357).

| Project | Cold | Edited | Cold baseline tests | Cold / edited mutants |
| --- | ---: | ---: | ---: | ---: |
| diff-lcs | 11.473 (11.030–11.871) | 10.882 (10.789–12.591) | 322 | 16 / 1 |
| tzinfo | 0.922 (0.753–1.075) | 0.930 (0.811–1.071) | 177 | 28 / 2 |
| hashdiff | 0.816 (0.773–0.983) | 0.752 (0.721–0.769) | 119 | 7 / 1 |
| Fizzy | 8.605 (6.343–10.569) | 9.097 (5.747–9.913) | 27 | 1 / 1 |

The disabled-instrumentation samples overlapped with their plain samples on this host. The table gives medians and observed ranges in milliseconds.

| Project | Plain | Inactive instrumentation | Disabled overhead |
| --- | ---: | ---: | ---: |
| diff-lcs | 9975.55 (7634.46–10525.58) | 10452.93 (9721.64–11185.37) | +4.8% |
| tzinfo | 15.91 (11.77–22.87) | 13.61 (11.44–19.91) | −14.5% |
| hashdiff | 37.35 (26.83–42.30) | 32.46 (24.47–39.79) | −13.1% |

### Fork warmup

On the same host and Ruby version, five alternating pairs on Fizzy ran 27 baseline tests and executed 15 mutants per run with four workers. Median wall time was 16.47 seconds without warmup (15.29–17.63) and 15.92 seconds with warmup (14.24–18.23). The ranges overlap and all mutation verdicts matched. The ripr code included the [SQLite snapshot fix](https://github.com/ydah/ripr/commit/67e8018).

Use the Fizzy setup above with `--rails --full --profile --jobs 4 --timeout-base 10000 --operators comparison,condition_negation,return_nil`. Target `app/models/assignment.rb` and `app/models/card/{assignable,taggable,closeable}.rb`. For the control, preload a Ruby file defining `def Process.warmup; end` via `RUBYOPT=-r/path/to/file.rb`.

### Cross-tool verdicts

With ripr at `e065271` and [Mutineer 1.8.2](https://github.com/davidteren/mutineer/tree/354c77deb972b2d6e663b5218e0a20b41217f69a), both tools killed all 52 comparison variants with identical source edits across the four pinned workloads. The handwritten oracle added eight executed pairs with matching verdicts, including six survivors, and one edit reached by neither tool.

Unpack the Mutineer 1.8.2 gem and pass its directory to `bundle exec ruby script/compare_verdicts.rb` to check the oracle. To check a corpus workload, add `--operators comparison` and pass the prepared project directory, mutated file, framework, and test globs after the Mutineer directory. Use `--rails` for Fizzy and `--mutineer-boot lib/diff-lcs.rb --mutineer-strategy redefine` for diff-lcs, whose whole-file reload would re-execute `undef :position`.

### Core diagnosis

At [`f17f988`](https://github.com/ydah/ripr/commit/f17f988) on Ruby 4.0.9, `bundle exec ruby script/self_mutate.rb` measured a 90.5% Core score. Of the 61 gaps whose v1 report kind was `not_detected`, three had unchanged observed exits and 13 had changes missed by tests. The remaining 45 lacked comparable, repeatable exit observations. The `core-mutations` CI artifact includes the per-mutation stages and examples.

### PostgreSQL worker setup

Seven paired runs on PostgreSQL 14 compared creating an empty worker database and restoring a dump against cloning the same snapshot as a template. Median worker setup fell from 77 to 62 ms for a 9.9 MB database with 2,000 rows and from 167 to 70 ms for a 22.2 MB database with 60,000 rows. Both produced the same data and schema checksums. Preparing the template adds one copy per ripr run.

### Compiler equivalence

On CRuby 3.3.12 and 4.0.9, all 695 valid dynamic variants from the four pinned files compiled with the full operator profile. No two variants shared the same normalized bytecode, and none matched the original. Both compilers detected a dead-branch control. The comparison retains instructions, operands, and line information and drops compiler node IDs and source columns.

Run `bundle exec ruby script/measure_tce.rb FILE ...` on the four files above to reproduce the counts. This measurement covers bytecode identity. Ripr uses test observations to report whether a mutation changes a method's behavior.

## Reproduce

Use Ruby 4.0.10, Bundler, Git, curl, tar, and the Fizzy system libraries listed in the [benchmark workflow](../.github/workflows/benchmark.yml). The runner downloads the archived revisions into temporary directories, installs dependencies, and writes wall-time samples, mutation counts, and ripr profiles to JSON.

```sh
ruby script/benchmark_corpus.rb run /tmp/ripr-benchmarks.json
ruby script/benchmark_corpus.rb trend /tmp/ripr-benchmarks.json
```

On macOS with Homebrew OpenSSL 4 as the default, set `BUNDLE_BUILD__OPENSSL=--with-openssl-dir=$(brew --prefix openssl@3)` for Fizzy's locked OpenSSL gem.

Every push to `main` runs the corpus on Ubuntu 24.04. The [Benchmarks workflow](https://github.com/ydah/ripr/actions/workflows/benchmark.yml) shows the trend across recent successful runs and publishes the underlying samples in its `ripr-benchmarks` artifact.
