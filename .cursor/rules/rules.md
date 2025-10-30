# Testing
- Do not use puts in /spec or /examples tests, unless it is truly temporary. Instead use Minigun.logger.info
- Whenever you create a file in /examples dir, always run `git update-index --chmod=+x <file_path>` to ensure it have execute permissions.
