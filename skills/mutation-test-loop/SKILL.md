---
name: mutation-test-loop
description: Improve Ruby tests using ripr mutation diagnostics, or triage ripr not_reached, not_infected, and not_detected results.
---

# Improve tests with ripr

Run `bundle exec ripr --since origin/main --reporter agent` from the project root.
Use `--full` for a complete audit or when no suitable Git reference exists.
A baseline failure must be fixed before interpreting mutation results.

For each entry in `gaps`, read the implementation and the listed tests, then follow its `action`:

- `add_test`: exercise the method and branch at `location`.
- `add_input`: turn a `suggested_inputs` pair into a valid input for the code under test. Each pair gives the left and right operands of the expression. If no pair is available, use `original`, `mutated`, and `observed` to find an input that changes the expression. For `age >= 18` becoming `age > 18`, the pair `[18,18]` suggests a test at `age = 18`.
- `strengthen_assertion`: assert a return value or side effect that belongs to the intended behavior. Infection can also fail to propagate, so inspect the surrounding code before adding an assertion.

After a focused test change, run `bundle exec ripr --only ID --reporter agent` using the gap's ID.
Confirm that the mutant is killed, and run the project's normal tests.
Keep implementation changes for separately demonstrated bugs; strengthen tests against the existing intended behavior.

If the mutation is equivalent under the documented specification, explain why and use
`bundle exec ripr accept ID --reason "specific specification-based reason"`.
Commit the resulting `ripr.accepted.yml` with the explanation.
Recheck stale acceptances after a method changes.

Finish when each targeted gap is killed or has a justified acceptance, and normal tests pass.
Report remaining gaps and failures explicitly. Assertions must check behavior; a higher score alone is insufficient justification for a test.
