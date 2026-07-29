# Helm v4 installation and upgrade design

**Date:** 2026-07-29
**Status:** Approved for implementation

## Goal

An operator installing Canton Data App v4 for the first time should be able to deploy it next to a standard Kubernetes Canton validator without reading the chart templates. An operator upgrading from Python v3.16.1 should get a hard failure before database mutation if they select the wrong persistent volume.

This work covers the chart, Auth0 installation path, v3 upgrade path, operator documentation, and chart verification. Keycloak testing will follow on an isolated localnet cluster. The setup wizard comes after the manual installation and migration paths work.

## Current prerelease images

The chart will use the images running in `noves-prod-ns` until Noves publishes the v4 artifacts:

| Component | Image |
|---|---|
| Backend | `noves.azurecr.io/cda-backend:prod-19b8de69-1785353655` |
| Frontend | `noves.azurecr.io/cda-frontend:prod-6110f60d-1785354653` |
| Database | `ghcr.io/noves-inc/noves-canton-database-v4:candidate-30160846627-1@sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b` |

The values schema will accept a digest for each image. Templates will render `repository:tag@digest` when the operator supplies a digest and `repository:tag` otherwise. `imagePullSecrets` stays available for private registries. The installation guide will tell the operator to arrange ACR and GHCR access before installing the release.

Noves will replace these defaults during the public release process. This task will not publish images, a chart, or a GitHub release.

## Routing contract

The chart will replace `routing.enabled`, `routing.istio.enabled`, and `routing.ingress.enabled` with one provider:

```yaml
routing:
  provider: ingress
  host: data.example.com
  tlsSecret: data-example-com-tls
  annotations: {}
  ingress:
    className: nginx
  istio:
    gateway: cluster-ingress/cn-http-gateway
```

`routing.provider` accepts `none`, `ingress`, or `istio`.

- `none` creates no public route.
- `ingress` creates a `networking.k8s.io/v1` Ingress and uses `routing.ingress.className`.
- `istio` creates a VirtualService and uses `routing.istio.gateway`.

Helm will reject a missing host for either public provider. It will reject `istio` when Helm has access to cluster capabilities and the cluster lacks the VirtualService API. Offline rendering cannot prove that a CRD exists, so the documentation and server-side dry-run remain part of the preflight.

The enterprise example will use `provider: ingress` with `className: nginx`. A separate Istio example will show the gateway field. The chart will not guess the provider from cluster state because client-side rendering and GitOps controllers do not expose the same discovery data.

## Accounting encryption key

The backend needs a unique 32-byte key to encrypt accounting OAuth credentials at rest. A shared application default would let one known key decrypt credentials from unrelated installations.

The chart will expose:

```yaml
accounting:
  tokenEncryption:
    existingSecret: ""
    key: accounting-token-encryption-key
```

An empty `existingSecret` tells Helm to create a release-scoped Secret. Helm will:

1. Reuse the existing generated value during an upgrade.
2. Generate 32 random bytes during the first installation.
3. Store the base64 representation expected by `ACCOUNTING_TOKEN_ENCRYPTION_KEY`.
4. Annotate the Secret with `helm.sh/resource-policy: keep`.

The backend Deployment will read the configured key from the generated or operator-owned Secret. Operators who use client-side GitOps rendering can supply an existing Secret to avoid a random rendered manifest. The documentation will tell operators to back up this Secret with the database because losing it makes stored accounting credentials unreadable.

## Artifact storage

Filesystem storage remains the default:

```yaml
exports:
  storage: pvc
  persistence:
    size: 20Gi
    storageClass: ""
```

The backend will mount the exports PVC at `/exports`. The frontend will not mount the claim because v4 sends artifact data through the backend API. Removing that mount prevents a second workload from attaching the ReadWriteOnce volume.

The chart will add typed optional S3 settings for exports and transaction-history backups. Each S3 block will support a bucket, endpoint URL, region, and a credentials Secret with keys for access key ID, secret access key, and an optional session token. The templates will map those settings to the existing `EXPORTS_S3_*` and `BACKUP_S3_*` variables.

Selecting S3 for exports removes the backend exports volume and claim. Omitting S3 settings keeps the PVC path. Backup S3 settings remain independent from export storage.

## Fresh-install contract

The chart will validate the inputs that the backend needs before Kubernetes accepts the release:

- one backend replica;
- a full participant ID;
- OIDC values for the selected provider;
- capture and Noves gateway Secret names and key names;
- routing fields for the selected provider;
- storage mode requirements;
- incompatible setup and migration modes.

The Auth0 installation guide will use a short operator sequence:

1. Confirm Kubernetes context, namespace, participant and validator Services, storage class, routing provider, and registry access.
2. Obtain the participant ID and create the capture user with copyable `grpcurl` commands.
3. Create the database, capture, gateway, and image-pull Secrets.
4. Install one values file.
5. Check `/health`, `/startup-status`, `/ready`, and `/api/v2/capture/status`.

The guide will explain that `/ready` proves application startup and schema readiness. The capture status endpoint proves that participant indexing is running. Troubleshooting will map common pod, routing, OIDC, database, and capture failures to the command that exposes the cause.

Provider guides will contain provider-specific steps. They will drop screenshot authoring notes, repeated introductions, and instructions such as "Capture only" or "Redact."

## Fail-closed v3 migration

`migration.enabled: true` will add a backend source expectation. The proposed environment name is:

```text
DATABASE_EXPECTED_SOURCE=v3
```

The database coordinator will enforce the expectation after classification and before extension provisioning or schema mutation. It will accept:

- a supported Python v3.16.1 database;
- a migration-managed database whose recorded bootstrap source is v3, which permits restart and replay resumption.

It will reject:

- an empty database;
- an unversioned C# database;
- a fresh v4 lineage;
- an unknown or unsupported database.

The coordinator will return the existing customer-facing migration error type and put the reason in `/startup-status`. Normal installations will omit `DATABASE_EXPECTED_SOURCE` and retain current automatic classification.

Tests will drive `DatabaseCoordinator.PrepareDatabaseAsync` against a real TimescaleDB. A regression test will prove that an empty database with the v3 expectation fails before the coordinator provisions extensions or writes the migration journal.

The chart will reject `migration.enabled: true` with `setupWizard.enabled: true`. Migration values remain in the Helm release after cutover because `migration.existingClaim` continues to select the converted database claim and the expectation accepts its recorded v3 lineage.

The migration guide will cover PVC discovery, snapshot or backup evidence, full v3 workload shutdown, proof that no pod mounts the claim, namespace placement, PostgreSQL major-version checks, startup monitoring, capture verification, and the post-cutover values lifecycle.

## Workload hardening

Backend and frontend containers will run without privilege escalation, with all Linux capabilities dropped and the runtime-default seccomp profile. The backend will declare its non-root runtime user. The chart will keep pod and container security context values configurable.

The database needs an empty-volume test and an existing-v3-volume test before the chart forces a non-root UID. The implementation will use the UID and group supported by the image only after both tests pass. A failed volume ownership test will leave the database security context configurable and document the remaining Pod Security requirement instead of shipping a default that prevents startup.

The chart will add a database ingress NetworkPolicy that permits PostgreSQL traffic from the backend pods. Broader frontend and backend policies require cluster-specific ingress-controller and egress selectors, so the chart will expose them as an opt-in block with documented selectors.

## Setup wizard

The setup wizard remains disabled by default and comes last in the implementation sequence.

The installer will preserve the complete routing object when it writes final values, including provider, host, TLS Secret, annotations, ingress class, and Istio gateway. The chart will reject setup and migration together.

The wizard will keep its private Deployment with no Service or public route. `NOTES.txt` and the wizard guide will port-forward the Deployment on container port 3000. The installer will continue to use localhost access and will switch the release to normal mode after setup.

## Verification

Chart tests will cover:

- each routing provider and invalid provider-specific combinations;
- generated and existing accounting Secrets;
- PVC and S3 export modes;
- S3 backup settings;
- image tags and digests;
- setup and migration mutual exclusion;
- v3 source-expectation injection;
- the absence of an exports mount in the frontend;
- security contexts and NetworkPolicies;
- corrected setup-wizard port-forward instructions.

Repository verification will run Helm lint, template fixtures, JSON-schema checks, documentation tests, installer tests, and the full `canton-data-app` test script. The backend change will start with a focused database integration test and finish with the complete backend test project.

The NGINX fixture will use `kubectl apply --dry-run=server` against `canton-mainnet`. The test will use the real `participant:5001` and `validator-app:5003` service shape without creating resources. The Istio fixture will use offline rendering until an Istio cluster is available.

## Implementation order

1. Add failing chart tests for routing, images, encryption, storage, and mode validation.
2. Implement the base values, schema, helpers, and templates.
3. Rewrite the Auth0 installation path and validate the NGINX render against `canton-mainnet`.
4. Add the backend v3 source expectation with a database integration test.
5. Update and test the v3 migration path.
6. Test workload security settings and add supported policies.
7. Repair and test the setup wizard.
8. Run both repositories' complete verification suites and review the rendered documentation.
