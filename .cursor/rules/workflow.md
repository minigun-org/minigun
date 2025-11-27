## Workflow
- **CRITICAL**: After making each change/feature, write tests for it.
- Consider if writing tests first makes more sense (TDD)
- After implementing a major feature fully and all tests passing, consider it a "Milestone". At each milestone:
    1. Write "Lore" automatically (see command below)
    2. Ask if I would like to "Harden" (see command below)
    3. Ask if I would like to "Lint" (see command below)

## Testing Rules
- **NEVER** jury-rig, skip, suppress, or delete tests because they are difficult. Instead, try to diagnose the problem, try alternative approaches.
- **NEVER** use mocks/doubles except for third-party APIs or external services.
- If considering shortcuts, STOP and ask first.
- **100% pass rate required** - 95% is not acceptable
- Avoid `sleep`/`timeout` in tests. Instead attach a listener/callback/hook (if readily available) or a check-loop that X component is ready/loaded, with some reasonably long timeout.

## Documentation
- Implementation summaries: Save to `/lore` folder (see "Lore" command above)
