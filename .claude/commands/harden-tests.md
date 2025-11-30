---
description: Assess and add more tests, then re-run tests (project)
---

Steps:
1. Do the Assess command: Review the recent changes in the thread holistically, and focus on test coverage.
   - Consider edge-cases, blind-spots, unit vs. integration tests.
   - Add missing test coverage
   - (BUT do NOT go overboard here.)
2. After adding tests -> re-run tests:
   - Ruby -> `bundle exec rspec`
