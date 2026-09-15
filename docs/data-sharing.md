# Optional Data Sharing

Data Sharing is awaiting the next public release. Validation currently targets DevNet; the pinned release images in this repository do not yet include the feature. Keep it disabled until installing a matching backend/frontend release that explicitly includes Data Sharing. These settings prepare that release and do not change image versions.

Data Sharing uses recipient consent, encrypted JSON/CSV pages and acknowledgments on Canton. The selected node must have the supported DAML package uploaded and vetted, and be connected to the configured synchronizer. Browser users need private party read rights; submission additionally requires `actAs` for the relevant controller. Public scan access does not grant payload access.

## Configuration

| Backend variable | Meaning |
| --- | --- |
| `DATA_SHARING_PACKAGE_ID` | Supported, uploaded and vetted package ID; 64 lowercase hexadecimal characters. Empty disables the feature. |
| `DATA_SHARING_SYNCHRONIZER_ID` | Exact synchronizer ID used for submissions. Required when enabling the feature. |
| `DATA_SHARING_STATE_DIR` | Private persistent state directory. The bundle uses `/data/data-sharing/state` inside the dedicated `/data/data-sharing` mount. |
| `DATA_SHARING_MAX_STORED_BYTES` | Local storage quota per node and party, in bytes. Default `1073741824` (1 GiB). This is separate from the agreement's delivery window and is not an aggregate volume limit. |

### Docker Compose

After the feature is released, set the package and synchronizer IDs in `.env`. The Compose bundle passes them to the backend and mounts the dedicated named volume `noves-canton-data-app-v4-sharing`; `DATA_SHARING_VOLUME` overrides its name. Leave the IDs empty to keep the feature disabled. Do not scale the backend: this storage implementation permits one writer process.

The compatible backend image prepares `/data/data-sharing` for its non-root application user, UID 1654. Existing or bind-mounted storage must allow that user to create and exclusively own the `state` subdirectory. Do not reuse the database or exports directory. Disabling the feature does not delete its volume.

### Helm

The feature is disabled by default. After installing a compatible release, configure:

```yaml
backend:
  replicaCount: 1
  dataSharing:
    enabled: true
    packageId: "<64-character-vetted-package-id>"
    synchronizerId: "<connected-synchronizer-id>"
    maxStoredBytes: 1073741824
    persistence:
      existingClaim: ""
      size: 10Gi
      storageClass: "<encrypted-block-storage-class>"
```

When enabled, the chart creates a dedicated `ReadWriteOnce` PVC unless `existingClaim` names an existing claim. The backend mounts it at `/data/data-sharing` and stores state in the private `state` subdirectory. The existing chart enforces one backend replica and the `Recreate` deployment strategy, so rolling replacements cannot concurrently write the directory. A chart-created claim has `helm.sh/resource-policy: keep`; disabling or uninstalling the feature must not silently destroy recipient keys.

The default security context runs the backend as UID 1654 with `fsGroup: 1654`. Select a storage driver that supports these permissions, exclusive file locking, atomic rename and durable file/directory flushes. Startup checks the configured filesystem before enabling normal operation. Size the PVC for all node/party quotas together, temporary writes and backup headroom; the 10 GiB default is not an aggregate quota enforced by the application.

## Backup, restore and retention

Back up the **entire state directory**, including recipient keys, intent metadata and all referenced payload/command blobs. A database backup or the transaction-history S3 backup alone does not contain this state. The directory includes plaintext deliveries and private keys; encrypt its backups and restrict access.

Stop the writer before taking a filesystem backup, or use a storage snapshot procedure that guarantees a consistent view of the whole directory. Restore the complete snapshot with the original ownership and node/party scope, then verify a pending delivery can still decrypt before resuming normal traffic. Changing a selected-node ID changes the storage scope. Losing recipient keys can make previously accepted pending deliveries unreadable; creating a new key does not repair an old grant.

The app saves verified plaintext before acknowledging receipt. An acknowledgment proves the protocol transition; it is not independent proof that an external storage system still retains the data. Manifests attest to delivery metadata and are checked against available local evidence.

Uncertain submissions retain their original command IDs. Recovery confirms success only from a matching committed command in retained participant history, or an exact supplied update ID that the participant verifies against the original command and party. A matching sequence alone is insufficient. If required history was pruned and no positive evidence remains, recovery refuses to infer success or submit a replacement automatically; operator investigation is required.

Deleting a local saved payload does not prune Canton history or erase copies already received by another party. Archiving a contract also does not delete historical ledger bytes. Participant pruning is a separate operator policy; do not prune evidence needed by unresolved submissions. Monitor local storage quotas and filesystem free space, and use the application's explicit local payload deletion controls rather than editing state files or removing keys.
