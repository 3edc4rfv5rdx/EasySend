# Working rules

When fixing findings from `ADD/tofix*.md`:

- Finish and verify one finding at a time.
- Add a concise one- or two-line entry under `CHANGELOG.md` → `Unreleased` for every completed fix.
- Run the relevant focused tests, `./05-Lint.sh`, and the full `./06-Test.sh` before calling a fix complete. Run the relevant Android/Kotlin build check when native code changes.
- Commit each completed fix immediately as its own commit and report the commit hash.
- Do not include pre-existing or unrelated working-tree changes in that commit.
