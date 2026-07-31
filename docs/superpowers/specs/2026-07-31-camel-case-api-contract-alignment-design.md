# CamelCase API Contract Alignment Design

**Date:** 2026-07-31
**Status:** Approved for implementation
**Repository:** `canton-data-app`

## Problem

The v4 deployment repository still documents and probes the backend startup
endpoint as `/startup-status`. The coordinated backend and frontend API
migration removed that route and replaced it with `/startupStatus`, so fresh
Compose and Helm installations now present operators with a stale diagnostic
URL and the Compose installer probes an endpoint that no longer exists.

The same API migration changed other route segments, query parameters, and JSON
properties. An audit against the complete merged rename maps found no references
to those retired public contract names in this repository.

## Scope

Update every operator-facing and executable `/startup-status` reference to
`/startupStatus` in:

- the Compose installer health probe and completion message;
- Helm installation notes;
- Compose, Helm, upgrade, and migration documentation; and
- documentation and installer contract tests.

The tests will require `/startupStatus` and reject `/startup-status`, reversing
the repository's current stale assertions.

## Non-goals

- Do not rename `synchronizer_alias`, `expected_synchronizer_id`, or other
  backend configuration fields. The application API migration explicitly
  preserved internal configuration, database, Canton Ledger API, and upstream
  payload names.
- Do not alter `/api/v2/capture/status` or other paths absent from the merged
  rename map.
- Do not add compatibility aliases, redirects, or endpoint implementations;
  this repository only packages and documents the application images.
- Do not mechanically convert arbitrary kebab-case or snake_case text.

## Implementation

Change the contract tests first so they encode the deployed backend contract:

- `tests/docs.sh` scans the operator-facing startup-contract files, fails when
  `/startup-status` remains, and requires `/startupStatus` in each file.
- `tests/installers.sh` makes its curl fixture recognize `/startupStatus`,
  requires both installer references to use it, and rejects the retired route.

Then update the matching production artifacts and documentation. The Compose
installer will continue treating the startup diagnostic as best-effort; only
the URL changes. Helm notes and guides retain their existing commands and prose
apart from the endpoint spelling.

## Contract audit

The final audit uses the complete route, parameter, and public JSON-property
rename maps from the merged backend camelCase design. Matches are changed only
when they represent the public HTTP contract. Internal or upstream formats are
reviewed and preserved according to that design's boundary rules.

At the time of this design, `/startup-status` is the only retired public name
present in `canton-data-app`. The remaining snake_case search hits are the
intentionally preserved node configuration keys named above.

## Verification

Run:

```bash
tests/docs.sh
tests/installers.sh
tests/all.sh
git diff --check
```

Finally, search the repository for every retired public route, query parameter,
and JSON property from the merged application contract. The search must find no
stale public-contract references; reviewed internal configuration matches are
allowed.

## Acceptance criteria

- A Compose installation probes and prints `/startupStatus`.
- Helm notes and all operator documentation direct users to `/startupStatus`.
- Contract tests fail if `/startup-status` is reintroduced.
- No identifier that remained unchanged in the backend or frontend is renamed.
- The complete repository verification suite passes.
