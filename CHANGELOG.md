# Changelog

## Unreleased

- Fix diff-driven mutation testing for non-ASCII paths and comments in the C locale.

## 0.2.0 — 2026-11-24

- Run mutation tests in Rails with isolated test databases or load a custom boot file.
- Keep Bootsnap enabled when using ripr's default loader.
- Opt into load-time mutations and an expanded operator profile.
- Select mutations covered by changed tests and reuse results using observed method dependencies.
- Verify kills on the original code and filter out mutants rejected by Sorbet or Steep.
- Use ripr from MCP clients over stdio.

## 0.1.0 — 2026-11-19

- Initial release.
