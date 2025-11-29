---
description: Fix linting issues and warnings, then re-run tests (project)
---

Run linters:
- Ruby -> `bundle exec rubocop -A` (autocorrect) then check any non-autocorrected warnings. Anything that isn't easily fixed, leave as-is then run `bundle exec rubocop --auto-gen-config --exclude-limit 1000`

Fix all issues and all warnings in the output (do not suppress them). Focus on getting all linter and warnings fixed.

Ignore any line-ending (CR-LF) warnings; these are just because we are using a Windows filesystem locally, but Git will handle them when we commit.

After linting is complete, re-run tests if there have been significant changes.
