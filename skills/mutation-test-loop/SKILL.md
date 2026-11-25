---
name: mutation-test-loop
description: Improve Ruby tests with ripr mutation diagnostics and prioritize gaps by diagnostic stage.
---

# Improve tests with ripr

Run `bundle exec ripr --since origin/main --reporter agent-v2` from the project root.
Use `--full` for a complete audit or when no suitable Git reference exists.
A baseline failure must be fixed before interpreting mutation results.

Start with the highest-priority entries in `gaps`. Use `methods` to find the first gap in each method. Read the implementation and the listed tests before following the gap's `action`.

- For `add_test`, exercise the method and branch at `location`.
- For `add_input`, turn a `suggested_inputs` pair into a valid input for the code under test. For `age >= 18` becoming `age > 18`, the pair `[18,18]` suggests a test at `age = 18`. For `not_propagated`, look for an input that makes the expression change an observable method exit.
- For `strengthen_assertion`, use `propagation` when available to find the missed change and the covering test. Assert the return value, exception, or side effect that the specification requires.

After a focused test change, run `bundle exec ripr --only ID --reporter agent-v2` using the gap's ID.
Confirm that the mutant is killed, and run the project's normal tests.
Keep implementation changes for separately demonstrated bugs; strengthen tests against the existing intended behavior.

If the mutation is equivalent under the documented specification, explain why and use
`bundle exec ripr accept ID --reason "specific specification-based reason"`.
Commit the resulting `ripr.accepted.yml` with the explanation.
Recheck stale acceptances after a method changes.

Finish when each targeted gap is killed or has a justified acceptance, and normal tests pass.
Report remaining gaps and failures explicitly. Assertions must check behavior; a higher score alone is insufficient justification for a test.
