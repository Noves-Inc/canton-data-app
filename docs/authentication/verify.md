# Verify authentication

Verify the browser and M2M paths separately. A successful browser sign-in does not prove that background indexing can authenticate, and a working M2M token does not authorize human users.

## M2M indexing

Before starting the Noves Data App, request another M2M indexing token and inspect it locally. Do not paste a production token into a third-party decoder. Confirm:

- `iss` is the configured identity-provider issuer;
- `aud` contains the participant Ledger API audience, whether `aud` is a string or an array;
- `sub` is non-empty and exactly matches the dedicated Canton M2M user; and
- the provider-required Ledger API scope is present when the deployment uses one.

The matching Canton user must have only `CanReadAsAnyParty`. If the same global M2M credentials serve multiple distinct participants, create the same user ID and right on every participant.

After installation, verify the backend:

```bash
curl -fsS http://127.0.0.1:8090/ready
curl -fsS http://127.0.0.1:8090/api/v2/capture/status | jq
```

`/ready` proves that required startup work completed. Inspect every node in the capture status response and confirm that M2M indexing is enabled and advancing.

## Browser sign-in

Open `APP_URL`, sign in with a normal human account through the configured identity provider, and confirm the browser returns to `APP_URL/callback`. Do not use the M2M service account for interactive sign-in.

Inspect the new browser access token locally and confirm:

- `iss` is the configured identity-provider issuer;
- `aud` contains the same participant Ledger API audience used by the working M2M token;
- the authorized-party or client claim identifies the public browser client when the provider emits that claim;
- the provider-required Ledger API scope is present when the deployment uses one; and
- `sub` exactly matches a Canton user on the selected participant.

The browser user's Canton rights determine the visible and actionable parties. Repeat the user and rights check on every participant that the user must access. Then confirm that the UI loads user rights, parties, and a representative private transaction query.

After changing an identity-provider scope or audience mapper, log out completely and sign in again so the browser obtains a new access token.

## Common failures

| Symptom | Check |
|---|---|
| Browser API returns `401` with `the provided jwt does not authorize you` | Compare the browser token's `iss` and Ledger API `aud` with a working token, then confirm its exact `sub` exists as a Canton user on the selected participant. |
| Startup fails while reading connected synchronizers | Check the M2M token endpoint, issuer, Ledger API audience, token `sub`, matching Canton user, and `CanReadAsAnyParty` right for the affected node. |
| One node works and another fails with global M2M credentials | Confirm the same M2M token subject exists as a Canton user on each distinct participant. |
| Configuration was corrected but the browser still fails | Log out and sign in again; existing access tokens do not gain newly configured claims. |

The app must also confirm the participant identity and network. Token issuance alone does not prove that either authentication path is authorized by Canton.
