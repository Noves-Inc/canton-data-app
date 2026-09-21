# Optional Data Sharing

Enable Data Sharing only with a backend/frontend release that includes it. The configuration in this change is validated for DevNet and leaves the feature disabled by default; it does not change release image versions.

Data Sharing uses recipient consent, encrypted JSON/CSV pages and acknowledgments on Canton. The selected participant must have the supported DAML package uploaded and vetted and be connected to the configured synchronizer. Browser users need private party read rights; submissions require `actAs` for the controller. Public scan access does not grant payload access.

## Reuse existing storage

Data Sharing stores its keys, pending commands, delivery metadata and payload blobs in **`/exports/data-sharing`**, a private subdirectory of the existing exports volume. It creates no additional PVC or Compose volume. The current filesystem store does not write this state through the S3 artifact provider.

The backend creates the subdirectory as UID 1654, with owner-only directory/file permissions. Do not point `DATA_SHARING_STATE_DIR` at `/exports` itself, change permissions on the whole exports mount, or register protocol files as disposable export artifacts. Export cleanup operates on stored export-job keys; Data Sharing uses its own retention rules. Both features share disk capacity, so monitor combined usage and leave temporary space for atomic state commits.

| Backend variable | Meaning |
| --- | --- |
| `DATA_SHARING_PACKAGE_ID` | Supported uploaded/vetted package ID, 64 lowercase hexadecimal characters. Empty disables the feature. |
| `DATA_SHARING_SYNCHRONIZER_ID` | Exact connected synchronizer used for submissions. |
| `DATA_SHARING_STATE_DIR` | `/exports/data-sharing` on the existing persistent exports mount. |
| `DATA_SHARING_MAX_STORED_BYTES` | Committed local storage quota per node/party; default 1 GiB (`1073741824`). This is not an aggregate volume limit or the protocol's delivery window. |

### Docker Compose

Set the package and synchronizer IDs in `.env` when using a compatible release. The existing `exports` volume is reused; `EXPORTS_VOLUME` continues to select its name. There is no `DATA_SHARING_VOLUME` setting. The backend must be able to create its private subdirectory on an existing or bind-mounted exports filesystem. Keep one backend writer.

Configuring exports to use S3 does not migrate Data Sharing state. Keep the existing `/exports` volume mounted and backed up while this feature uses it.

### Helm

Configure the existing exports PVC and enable the feature:

```yaml
exports:
  storage: pvc
backend:
  replicaCount: 1
  dataSharing:
    enabled: true
    packageId: "<64-character-vetted-package-id>"
    synchronizerId: "<connected-synchronizer-id>"
    maxStoredBytes: 1073741824
```

The chart preserves its single-backend `Recreate` strategy. Enabling Data Sharing requires `exports.storage=pvc`; rendering fails for an S3-only configuration because that configuration would remove the required local mount. Data Sharing does not increase the configured exports PVC size automatically. Size it for export jobs, all sharing quotas together, backups and temporary write headroom.

## Backup, restore and retention

The exports volume now also contains **durable recipient keys and protocol state**. It is no longer safe to discard the volume merely because export artifacts can be regenerated. Preserve it when disabling Data Sharing, changing export providers, upgrading or uninstalling. Keep the chart's existing PVC retention behavior.

Back up the complete `/exports/data-sharing` directory, including keys, metadata and every referenced blob, with the writer stopped or a consistent filesystem snapshot. These files contain private keys and plaintext; encrypt backups and restrict access. A database backup or S3 export migration does not include them.

Restore the original ownership and node/party scope, then verify decryption and saved history before resuming traffic. Node-ID changes require an explicit scope migration. A replacement recipient key cannot decrypt data encrypted for an old accepted grant.

For installations of the earlier prototype at `/data/data-sharing/state`, stop its writer, copy the complete directory into an absent `/exports/data-sharing`, verify every file, and update the configured path. Retain the old volume and private backup until the new location passes application/restart checks. Do not merge independently modified state directories or delete a pending intent to unblock a send.

## Recovery semantics

The app saves verified plaintext before acknowledging receipt. An acknowledgment is a protocol transition, not independent proof of continued external storage. Manifests attest to delivery metadata and are compared with retained local evidence.

Uncertain submissions retain their original command IDs. Recovery requires a matching committed command in retained participant history or an exact supplied update ID verified against the original command and party. Missing/pruned evidence cannot confirm success. The application does not infer success from a matching sequence or automatically submit a replacement outside its safe retry period.

Removing an acknowledged local payload retains delivery evidence. It does not prune Canton history or erase another party's copy. Archiving a DAML contract also does not delete historical ledger bytes; participant pruning is a separate operator policy.
