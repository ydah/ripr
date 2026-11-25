# Changelog

## Unreleased

- Fix diff-driven mutation testing for non-ASCII paths and comments in the C locale.
- Write phase timings, test counts, and cache hit rates with `--profile`.
- Prioritize previously killing tests within the test framework's ordering rules.
- Suggest operands that distinguish a comparison or arithmetic mutation from the original expression.
- Warm the parent process before forking and cap automatic worker counts by available memory.
- Avoid SQLite snapshot lock contention between Rails workers.
- Skip equivalent native array additions and subtractions with an empty right operand.
- Distinguish unchanged method exits from changed returns or exceptions missed by assertions.
- Group gaps by method and expose ranked diagnostics through agent JSON v2.
- Include an offline HTML viewer with a diagnostic stage filter.

## 0.2.0 — 2026-11-24

- Run mutation tests in Rails with isolated test databases or load a custom boot file.
- Keep Bootsnap enabled when using ripr's default loader.
- Opt into load-time mutations and an expanded operator profile.
- Select mutations covered by changed tests and reuse results using observed method dependencies.
- Verify kills on the original code and filter out mutants rejected by Sorbet or Steep.
- Use ripr from MCP clients over stdio.

## 0.1.0 — 2026-11-19

- Initial release.
