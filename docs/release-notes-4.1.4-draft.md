# Noves Data App 4.1.4 release notes (draft)

This draft is finalized in the 4.1.4 release bundle commit, which also pins the published image digests.

## Per-installation credentials

In 4.1.4 each installation has its own credential for account features, which the app sets up automatically. Earlier releases share one credential across every installation; 4.1.4 replaces it with a signing key that belongs to the installation alone:

1. On first start, the backend generates a signing key and stores it encrypted in the database.
2. Noves places a private enrollment challenge on the ledger that only your validator party can see. The backend reads it through its own participant connection and answers it, which binds the installation to the account that owns that validator party.
3. The backend and the frontend each run a health check through the new path. The installation then waits until no installation of its account has used the previous credential for 72 hours, or until an account admin confirms that every installation runs 4.1.4 (see [Upgrade every installation of an account](#upgrade-every-installation-of-an-account)). After that it becomes active, and the account uses per-installation credentials from then on.

Enrollment is automatic, and every function keeps working while it runs. From the moment enrollment succeeds, the installation signs its account calls with its own credential.

### Check the enrollment status

Open the **Backend Status** page and find the **Installation Identity** section. It lists each node with its status:

| Status | Meaning |
|---|---|
| `Enrolling` | The installation is answering its enrollment challenge. |
| `Activating` | Enrollment succeeded and the installation is running its health checks. |
| `Waiting for older Data App requests to stop` | Enrollment and health checks succeeded. The account still receives requests from a Data App on 4.1.3 or earlier, so it waits before switching to per-installation credentials (see [While the account waits for the switch](#while-the-account-waits-for-the-switch)). |
| `Active` | The installation is active, and its account uses per-installation credentials. |
| `Not enrollable` | The node cannot enroll. The page shows: "This node cannot enroll its installation. Contact support if this persists." |
| `Revoked` | The page shows: "This installation no longer has a credential in use. Contact support to enroll it again." |
| `Unknown` | The page shows: "The installation state of this node is not recognized." |

An installation can show `Waiting for older Data App requests to stop` for up to 72 hours after the last request from an older Data App on the same account. That is expected, and every function keeps working while it waits.

Account features are the Platform API key, the Account page with its users and plan, purchases, add-ons, subscription linking, and earnings withdrawal. Indexing, ledger access, dashboards, reports, and exports do not depend on the credential.

## Before you upgrade

**Ledger connection.** Enrollment reads the challenge through the backend's participant connection, so that connection must be able to read as your validator party. An installation whose Ledger API connection or M2M indexing credential is not configured cannot enroll. The Backend Status page shows it as `Not enrollable`, and it keeps the 4.1.3 behaviour until its account switches to per-installation credentials (see below). Data App v3 installations do not enroll either.

**Requests to Noves account services.** The signed gateway has a 65,536-byte body limit for account and subscription requests. A larger body returns `413 body_too_large`, even while the account still accepts the previous shared credential. The previous unsigned gateway did not impose this contract limit. If a custom integration calls these services directly, check its request sizes before upgrading. Legacy query parameters keep their previous form parsing; send uncompressed JSON. See the [Security model](security.md#installation-credential-secrets) for the request limits.

**New secrets, no new configuration.** Helm and the Compose installer generate two new secrets automatically:

- an installation key-encryption key (KEK), mounted only into the backend;
- a canary capability, shared by the frontend and the backend, never sent to browsers.

**Back up the KEK together with the database, and restore them together.** The database without its KEK cannot use its installation credential. Helm keeps the generated KEK Secret during uninstall and refuses to replace it while the release's live backend depends on it; renaming the release or changing `fullnameOverride` requires `installation.kek.existingSecret` pointing at the retained KEK; the Compose installer keeps `.state/installation-kek` and refuses to replace it once it has created one. Operators who render the chart client-side, for example with Argo CD, set `installation.kek.existingSecret` and `installation.canary.existingSecret`. See [Helm installation](helm.md#4-create-application-secrets), [Docker Compose installation](docker-compose.md#installation-credential-secrets), and [Security model](security.md#installation-credential-secrets).

The Compose installer now recreates the backend and frontend containers on every run, so both read the same canary capability.

## Upgrade every installation of an account

Many accounts link more than one validator party, for example mainnet and testnet, and run one Data App installation for each. **Upgrade every Data App installation on the account to 4.1.4 first.** An installation that stays on 4.1.3 or earlier stops working for account features after the switch.

The account switches to per-installation credentials automatically once none of its installations has used the previous credential for 72 hours. Until then everything keeps working, on 4.1.3 and on 4.1.4 installations alike. An installation running 4.1.3 or an earlier release uses the previous credential on every request, so:

- **A 4.1.3 or older installation that is still running keeps the switch from happening.** The upgraded installations show `Waiting for older Data App requests to stop` until it is upgraded or shut down and 72 hours have passed since its last request, or until an account admin confirms that every installation runs 4.1.4.
- **An installation that comes back after the switch must be upgraded.** For example, a testnet installation that was switched off for more than 72 hours and is started again on 4.1.3 keeps indexing, ledger access, dashboards, and reports, but has no account features. Upgrade it to 4.1.4 with its own database and KEK; it enrolls as another installation of the account and gets its account features back automatically.

### While the account waits for the switch

Every function keeps working while the account waits, on 4.1.3 and on 4.1.4 installations alike.

Account admins see a notice in the app titled **Complete your upgrade to 4.1.4**. It reads: "Your account still receives requests from an older Data App (4.1.3 or earlier), last seen *time ago*. Once every installation runs 4.1.4, the switch to per-installation credentials completes on its own, on *date* if nothing else arrives. If all your installations already run 4.1.4, confirm it below." The detail is on the **Backend Status** page, in the **Installation Identity** section: the status `Waiting for older Data App requests to stop`, the time of the last request from an older Data App, when the account switches on its own, and the button **All my installations run 4.1.4**. Users who are not account admins see "Only an admin of this account can confirm this." in place of the button.

Once every installation on the account runs 4.1.4, an account admin can select **All my installations run 4.1.4** to complete the switch right away instead of waiting for the 72 hours. A dialog asks for confirmation first: "Any Data App on this account that still runs 4.1.3 or earlier will stop working for account features. Continue?" If the confirmation cannot be sent, the page shows "The confirmation could not be sent. Try again." The confirmation applies to the account permanently: a 4.1.3 installation started later does not hold the account in waiting again, and has no account features until it is upgraded. [support@noves.fi](mailto:support@noves.fi) can also complete the switch for the account.

After the switch, the account accepts only per-installation credentials for account features. A new installation starts from its own empty database and enrolls on its own. A copy of an existing installation's database and KEK must never run as a second installation; see [Security model](security.md#installation-credential-secrets).

## Rolling back

After the account switches to per-installation credentials, it no longer accepts the previous credential that 4.1.3 and earlier releases use. An installation rolled back to one of those releases keeps indexing, ledger access, dashboards, and reports working, but loses its account features. Before the switch, a rollback keeps everything working and starts the 72 hour wait again, because the rolled back installation uses the previous credential. To roll back, move to another 4.1.4 or later build and keep the same database and KEK.

## Recommended: a Ledger API audience on the participant

The backend now validates each browser sign-in through your participant before it acts on the account. The participant checks the token's audience only when its Ledger API JWT authentication is configured with one (`target-audience`). Without an audience, an access token that your identity provider issued to the same user for a different application is also accepted for that user. Configure the participant with your Ledger API audience, and keep that audience in both the browser and the M2M tokens, as the [Security model](security.md#identities) requires.
