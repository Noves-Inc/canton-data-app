# Canton Data App 4.2.3

## Public parties

- Search public parties by name, Featured App name, or party ID fragment without requiring Canton Analytics.
- Export a public party as Financial CSV, Activity CSV, or raw JSON without a connected validator or local indexing. Canton Coin transfers include price enrichment where available.
- Explore public validator activity, rewards, balances, and traffic information in the Validator view.

## Reports and exports

- Asset Issuer and Venue Partner Reports show clearer downloads, validator-level DvP status, and correct links to confirmations and report history.
- Larger full-day partner reports can calculate and download their settlement allocations.
- CSV downloads use readable labels, start with column headers, and include Traffic Cost USD alongside Traffic Cost Bytes where available.

## Reliability and setup

- Improved validator-summary initialization and public-summary performance.
- Clearer installation enrollment and account setup states.
- Improved recovery when a browser has an older application page open during an upgrade.

## Upgrade

Use all three image pins and the chart or Compose files from this release. Read the [upgrade guide](upgrade-4.2.2.md) before upgrading, including database backup and rollback requirements.

For Helm, use the attached `noves-canton-app-4.2.3.tgz` chart and your own values file; do not use `--reuse-values`. The release manifest records the image digests, and `SHA256SUMS` covers the attached release files.
