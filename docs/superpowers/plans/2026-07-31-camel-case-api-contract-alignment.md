# CamelCase API Contract Alignment Implementation Plan

> **For agentic workers:** Execute each task test-first and review the exact diff before committing.

**Goal:** Align the v4 deployment repository with the merged backend/frontend camelCase HTTP contract without renaming internal configuration fields.

**Architecture:** Treat the application repositories' approved rename maps as the source of truth. Change v4 contract tests first, then update the installer, chart notes, and operator documentation that contain the one retired public identifier found by the audit: `/startup-status`.

**Tech Stack:** Bash, Helm templates, Markdown, ripgrep.

---

### Task 1: Reverse the stale contract assertions

**Files:**
- Modify: `tests/docs.sh`
- Modify: `tests/installers.sh`

- [ ] Require `/startupStatus` in every startup-contract artifact.
- [ ] Reject `/startup-status` as the retired route.
- [ ] Update the fake curl handler to recognize `/startupStatus`.
- [ ] Run `tests/docs.sh` and `tests/installers.sh`; confirm they fail against the unchanged production artifacts.

### Task 2: Update executable and rendered deployment artifacts

**Files:**
- Modify: `scripts/install-compose.sh`
- Modify: `chart/noves-canton-data-app/templates/NOTES.txt`

- [ ] Change the failed-readiness diagnostic probe to `/startupStatus`.
- [ ] Change the successful Compose installation output to `/startupStatus`.
- [ ] Change the Helm startup diagnostic command to `/startupStatus`.
- [ ] Rerun `tests/docs.sh` and `tests/installers.sh`; keep failures attributable only to documentation that has not yet been updated.

### Task 3: Update operator documentation

**Files:**
- Modify: `docs/helm.md`
- Modify: `docs/docker-compose.md`
- Modify: `docs/upgrades.md`
- Modify: `docs/migrate-v3.16.1.md`

- [ ] Replace each operator command or reference to `/startup-status` with `/startupStatus`.
- [ ] Preserve surrounding instructions and all unrelated endpoints.
- [ ] Run `tests/docs.sh` and `tests/installers.sh`; confirm both pass.

### Task 4: Verify the complete migration boundary

**Files:**
- Review all changed files.

- [ ] Search for every retired route segment from the merged backend contract.
- [ ] Search for every retired query and public JSON property name.
- [ ] Confirm no stale public-contract matches remain.
- [ ] Confirm any remaining `synchronizer_alias` and `expected_synchronizer_id` matches are internal node configuration and remain unchanged.
- [ ] Run `tests/all.sh`.
- [ ] Run `git diff --check`.
- [ ] Inspect `git status --short --branch` and the final diff.

### Task 5: Commit the implementation

- [ ] Stage only the tests, installer, chart notes, and documentation listed above.
- [ ] Inspect the staged path list and staged diff.
- [ ] Commit with a focused message.
- [ ] Do not push without explicit user authorization.
