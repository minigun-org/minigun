## Workflow
- **CRITICAL**: After making each change/feature, write tests for it.
- Consider if writing tests first makes more sense (TDD)
- After implementing a major feature fully and all tests passing, consider it a "Milestone". At each milestone:
    1. Write "Lore" automatically (see command below)
    2. Ask if I would like to "Harden" (see command below)
    3. Ask if I would like to "Lint" (see command below)

## Testing Rules
- **NEVER** jury-rig, skip, suppress, or delete tests because they are difficult. Instead, try to diagnose the problem, try alternative approaches.
  - If considering shortcuts, STOP and ask first.
- **NEVER** implement no-op tests, or simplify tests to the point where the are meaningless.
  - If you want to "simplify" a test, make a new scratch file to test the simplification, then apply the learnings to the original test. 
- **NEVER** use mocks/doubles except for third-party APIs or external services.
- **100% pass rate required** - 95% is not acceptable.
- Do not make pending tests unless explicitly asked to. All tests must be runnable by CI; no "manual only" tests.
- Avoid `sleep`/`timeout` in tests, especially when dealing with multi-threaded or multi-process scenarios.
  - Instead attach a listener/callback/hook (if readily available) or a check-loop that X component is ready/loaded, with some reasonably long timeout.

## Examples (Tests)
- Whenever you create a file in /examples dir:
  - Run `git update-index --chmod=+x <file_path>` to ensure it have execute permissions.
  - Add the example to `spec/integration/examples_spec.rb`

## Documentation
- Implementation summaries: Save to `/lore` folder (see "Lore" command above)
