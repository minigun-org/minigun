---
description: Assess and auto-refactor if confident, then re-run tests (project)
---

Steps:
1. Before starting -> If there are uncommitted git changes, ask if I would like to commit
2. Do the Assess command: Review the recent changes in the thread holistically and make a refactor/cleanup plan:
   - Consolidate code
   - Fix implementation inconsistencies
   - Fix anything hacky/bloated/redundant
   - DRY up code / extract out a common component (do NOT go overboard)
   - Remove dead/unused/obsolete code
   - Add missing test coverage
   - (BUT do NOT go overboard here; focus on obvious problems and obvious wins.)
3. Write the plan to the lore folder (filename: "%Y%m%d-%H%M-lowercase-name.md" format with leading zeros)
4. If you are 95%+ confident the refactor/cleanups will be an obvious "slam-dunk" improvement, go ahead and do it automatically. Otherwise write Lore and ask me.
5. After completing refactors -> re-run tests:
   - Ruby -> `bundle exec rspec`
