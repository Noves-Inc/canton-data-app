# Account and installation setup

An existing Noves account and a fresh Data App installation are separate. Reinstalling with a new database does not delete the account, but the installation must identify its validator and complete its own verification before it can use account services.

The Data App needs the full validator party ID for the connected node and network. A party selected in the browser is not necessarily the validator party. Confirm the value with your validator operator; do not substitute another locally hosted party.

## Configure the validator party

Automatic discovery can learn the validator party from indexed validator activity. To avoid waiting for that discovery on a fresh installation, configure the known validator party explicitly.

The supplied Docker Compose and Helm deployments use a node configuration file. In that file, add `validator_party` inside the matching node entry: `nodes.<node-id>.validator_party`. Keep its existing `addr`, authentication, TLS and other settings. The example below uses the node ID `main-node`; use the node ID already present in your file.

The supplied bundle names this file `nodes-config.json`. If your deployment loads a custom file such as `nodes_config.json` through `NODES_CONFIG_FILE_PATH`, edit that configured file instead. The JSON field is the same in either case:

```json
{
  "primaryNodeId": "main-node",
  "nodes": {
    "main-node": {
      "addr": "participant:5001",
      "validator_party": "YOUR_FULL_VALIDATOR_PARTY_ID"
    }
  }
}
```

For Compose, edit `.state/nodes-config.json` in the installation's `docker-compose` directory, then restart the backend:

```bash
cd "$APP_INSTALL_DIR/docker-compose"
docker compose --env-file .env -f compose.yaml restart backend
```

For Helm, set `validatorParty` on the corresponding entry in `canton.nodes` in your retained values file. The chart writes it as `validator_party` in the node configuration. Apply the change using the [Helm upgrade instructions](helm.md) and ensure the backend restarts with the updated configuration.

A custom single-node deployment that does **not** load a node configuration file (either through `NODES_CONFIG_FILE_PATH` or the default `/config/nodes-config.json`) can instead set the backend container environment variable:

```dotenv
VALIDATOR_PARTY_ID=YOUR_FULL_VALIDATOR_PARTY_ID
```

Recreate or roll out the container with the updated environment. A plain Docker restart does not apply changed environment variables. Setting this only in a host shell or an unreferenced `.env` file does not configure the container. When a node configuration file is used, set its per-node `validator_party`; the global variable is not a substitute.

Use the correct identity separately for testnet and mainnet. An explicit party setting does not bypass installation verification or grant account membership.

## Distinguish setup problems

| Problem | Action |
|---|---|
| Validator identity is not available | Configure the full validator party as above and restart the backend. |
| Backend cannot authenticate to or reach the participant | Check the [M2M configuration](docker-compose.md#3-configure-browser-login-and-m2m-indexing), participant address and TLS settings. Setting a validator party cannot repair this connection. |
| Network identity cannot be resolved | Check backend startup status and the configured synchronizer alias. Do not change the validator party to guess a network. |
| Installation verification is pending | Allow the automatic verification to finish. If it persists, check that the backend M2M connection can read the validator party's private ledger data and contact Noves support. |
| Your user is not an account member | Ask an existing account administrator to grant access. Reinstalling or entering company details does not grant membership. |
| Noves account services are temporarily unavailable | Retry later. This does not mean the existing account was deleted or that you should create a replacement. |

Use the Backend Status page and the backend's `/startupStatus` endpoint to distinguish startup failures from account-service errors. When contacting support, include the app version and the displayed error/reference, without tokens, cookies, private keys or private transaction contents.

## Planned 4.2.3 onboarding behavior

These UI changes are part of the pending 4.2.3 release. Earlier versions can display a generic account-setup form for failures that require an operator action.

In 4.2.3, installation problems show setup guidance separately from account profile completion. Existing authorized members return to their account after successful setup. The organization/contact form appears only after account services confirm that profile information is missing, including an incomplete existing profile. A failed lookup or a membership refusal does not open registration. Temporary enrollment states retry for a bounded period and then offer a manual retry.
