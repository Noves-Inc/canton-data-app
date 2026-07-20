# Encryption at Rest (v4)

Starting with v4, deployments of the Data App are expected to keep the indexed ledger data **encrypted at rest**. The application itself already encrypts stored credentials (OAuth tokens and similar secrets) at the column level; the indexed transaction data is protected by **transparent encryption of the storage that backs the database volume**. This is deliberate: transparent (disk/volume-level) encryption protects the data on disk with zero impact on queries, search, or dashboard aggregations, and requires no changes to the application containers.

Because the Data App runs in **your** infrastructure, the encrypted storage is something you configure in your environment. This guide tells you exactly what needs to be encrypted, how to do it in each deployment mode, how to migrate an existing unencrypted deployment, and how to verify the result.

## You May Already Be Done

If your deployment runs on a major cloud, the storage under the database volume is likely **already encrypted at rest by default** — in that case there is nothing to set up, only something to verify:

| Where you run | Default state | How to verify |
|---|---|---|
| **GCP** (GKE or VMs) | ✅ All persistent disks always encrypted | Nothing to check — it cannot be disabled. Optionally add a customer-managed key (CMEK). |
| **Azure** (AKS or VMs) | ✅ All managed disks always encrypted (platform-managed keys) | Nothing to check. Optionally add your own key via a Disk Encryption Set. |
| **AWS** (EKS or EC2) | ✅ if "EBS encryption by default" is enabled on the account/region (common) | `aws ec2 get-ebs-encryption-by-default`, or check the specific volume: `aws ec2 describe-volumes --query 'Volumes[].Encrypted'` |
| **Bare metal / own hypervisor** | ❌ Not unless you set it up | `lsblk -o NAME,TYPE,MOUNTPOINT` — the device under the DB volume should show type `crypt` |

If the table above already covers you with a ✅ (and your compliance requirements don't demand customer-managed keys), you can skip straight to [Backups and Exports](#backups-and-exports) and the [Verification Checklist](#verification-checklist). The rest of this guide is for bare-metal deployments and for teams that want their own keys.

---

## Table of Contents

1. [What Must Be Encrypted](#what-must-be-encrypted)
2. [Threat Model — What This Does and Does Not Protect](#threat-model--what-this-does-and-does-not-protect)
3. [Docker Compose Deployments](#docker-compose-deployments)
   - [New Installations](#new-installations)
   - [Migrating an Existing Deployment](#migrating-an-existing-deployment)
   - [Setting Up an Encrypted Filesystem with LUKS](#setting-up-an-encrypted-filesystem-with-luks)
4. [Kubernetes Deployments](#kubernetes-deployments)
   - [Encrypted StorageClass Examples](#encrypted-storageclass-examples)
   - [Migrating an Existing PVC](#migrating-an-existing-pvc)
5. [Backups and Exports](#backups-and-exports)
6. [Key Management](#key-management)
7. [Verification Checklist](#verification-checklist)

---

## What Must Be Encrypted

The database container (`canton-data-app-db` / `data-app-db`) is the **only stateful component** — everything sensitive that the Data App persists lives in its Postgres data directory:

| Data | Where it lives | Covered by |
|---|---|---|
| Indexed transactions, contracts, balances, party data | Postgres data volume | **Encrypted volume (this guide)** |
| Postgres WAL, temp files, indexes | Same data volume (`PGDATA`) | Encrypted volume — nothing spills outside it |
| Stored credentials (OAuth secrets, API keys) | Postgres, dedicated columns | Already encrypted by the app (AES-256-GCM) |
| Transaction history backups | Your `BACKUP_S3_*` bucket | Bucket-side encryption — see [Backups and Exports](#backups-and-exports) |
| CSV / cost-basis exports | Your `EXPORTS_S3_*` (or backup) bucket | Bucket-side encryption — see [Backups and Exports](#backups-and-exports) |

The frontend and backend containers are stateless; they hold data only in memory.

> **Optional hardening:** container runtime logs (Docker's `json-file` logs, kubelet logs) can occasionally contain fragments of query text from Postgres error messages. If your compliance bar requires it, place the container runtime's log/data directory on encrypted storage as well (on most cloud VMs the OS disk is already encrypted by the platform).

## Threat Model — What This Does and Does Not Protect

Transparent volume encryption protects against **offline access to the stored bytes**: stolen or improperly decommissioned disks, leaked volume snapshots, and hosts whose storage is accessed outside the running system. This matches the protection level of the Canton validator node's own database.

It does **not** protect against an attacker who has live access to the running host or valid database credentials — a running system necessarily sees its own data decrypted. Protect that layer operationally: restrict who holds the Postgres password (set via `CANTON_TRANSLATE_DB_PASSWORD` / the `data-app-db-secret`), don't expose port 5432 beyond the app's network, and control host/cluster access.

---

## Docker Compose Deployments

In compose mode the database stores its data in the `canton-data-app-db-data` volume. By default that is a named Docker volume under `/var/lib/docker/volumes` — encrypted only if that path happens to sit on an encrypted disk.

The v4 compose file makes the data location configurable via the `CANTON_DATA_APP_DB_DATA` variable:

```yaml
volumes:
  - ${CANTON_DATA_APP_DB_DATA:-canton-data-app-db-data}:/home/postgres/pgdata
```

- **Unset** (default): behaves exactly as before — the named Docker volume. No action needed for existing deployments until you migrate.
- **Set to an absolute path**: the database stores its data at that path on the host. Point it at a directory on an **encrypted filesystem** and the indexed data is encrypted at rest.

Set it in a `.env` file next to `compose.yaml` (compose reads it automatically):

```bash
# .env
CANTON_TRANSLATE_DB_PASSWORD=<your-db-password>
CANTON_DATA_APP_DB_DATA=/mnt/canton-encrypted/db
```

There are two equally valid ways to get an encrypted filesystem under that path — pick whichever fits your environment:

1. **Cloud VM:** attach a block volume with the provider's encryption enabled (AWS EBS encrypted volume, Azure disk with SSE, GCP encrypted PD — all support customer-managed keys), format and mount it, e.g. at `/mnt/canton-encrypted`. Nothing else is needed; skip to [New Installations](#new-installations).
2. **Bare metal / your own hypervisor:** use LUKS (standard Linux disk encryption) — see [the LUKS walkthrough below](#setting-up-an-encrypted-filesystem-with-luks). ZFS native encryption or an encrypted LVM volume work just as well if you already operate them.

### New Installations

1. Prepare the encrypted filesystem and mount it (e.g. at `/mnt/canton-encrypted`).
2. Create the data directory: `mkdir -p /mnt/canton-encrypted/db`
3. Set `CANTON_DATA_APP_DB_DATA=/mnt/canton-encrypted/db` in `.env`.
4. `docker compose up -d` — the database initializes directly onto encrypted storage.

> If Postgres fails to start with a permissions error on first boot, give the postgres user in the container ownership of the directory: check the uid in the error message and `chown -R <uid> /mnt/canton-encrypted/db`.

### Migrating an Existing Deployment

Your existing data is in the named volume. The migration is a file copy — no dump/restore, no re-index, and the capture cursor is preserved. Downtime is the duration of the copy (minutes for typical volumes).

```bash
cd <your-deployment-directory>

# 1. Stop the app (database last so nothing writes during the copy)
docker compose down

# 2. Copy the data from the named volume to the encrypted path (preserves ownership/permissions)
mkdir -p /mnt/canton-encrypted/db
docker run --rm \
  -v canton-data-app-db-data:/from:ro \
  -v /mnt/canton-encrypted/db:/to \
  alpine cp -a /from/. /to/

# 3. Point the deployment at the new location
echo 'CANTON_DATA_APP_DB_DATA=/mnt/canton-encrypted/db' >> .env

# 4. Start and verify
docker compose up -d
docker compose logs -f canton-data-app-backend   # indexing resumes from where it left off
```

5. Once verified (dashboard loads, indexing advances), delete the old **unencrypted** volume — leaving it around defeats the purpose:

```bash
docker volume rm canton-data-app-db-data
```

### Setting Up an Encrypted Filesystem with LUKS

For bare-metal hosts. Requires a spare block device or partition (`/dev/sdX` below — **double-check the device name; formatting is destructive**).

```bash
# 1. Create the LUKS container (you will be prompted for a passphrase)
cryptsetup luksFormat /dev/sdX

# 2. Open it and create a filesystem
cryptsetup open /dev/sdX canton_encrypted
mkfs.ext4 /dev/mapper/canton_encrypted

# 3. Mount it
mkdir -p /mnt/canton-encrypted
mount /dev/mapper/canton_encrypted /mnt/canton-encrypted
```

To have it available across reboots, add entries to `/etc/crypttab` and `/etc/fstab`:

```
# /etc/crypttab — unlock with a key file (see Key Management for where to keep it),
# or omit the key file to be prompted on the console at boot
canton_encrypted  /dev/sdX  /root/canton_encrypted.key  luks

# /etc/fstab
/dev/mapper/canton_encrypted  /mnt/canton-encrypted  ext4  defaults,nofail  0 2
```

> With `nofail` + Docker's `restart: unless-stopped`, make sure the mount is up before the containers start (e.g. a systemd unit ordering, or simply verify after reboot). If the mount is missing, the bind mount will fail and the database container will not start — which is the safe failure mode (it will not silently write unencrypted data).

## Kubernetes Deployments

In Kubernetes mode the database mounts `data-app-db-pvc`. Whether that PVC is encrypted is determined entirely by its **StorageClass**. The v4 manifest carries an explicit `storageClassName` field — set it to a StorageClass that provisions encrypted volumes in your cluster:

```yaml
# kubernetes/manifests/persistentvolumeclaims.yaml
spec:
  storageClassName: <your-encrypted-storageclass>   # REQUIRED for encryption at rest
```

### Encrypted StorageClass Examples

Use these as templates — the mechanism depends on where your cluster runs. In all cases the application manifests need nothing beyond the `storageClassName`.

**AWS (EBS CSI):**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  # kmsKeyId: <your KMS key ARN>   # omit to use the AWS-managed key
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

**Azure (AKS, customer-managed keys via a Disk Encryption Set):**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-cmk
provisioner: disk.csi.azure.com
parameters:
  skuname: StandardSSD_LRS
  diskEncryptionSetID: "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/diskEncryptionSets/<des>"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

> Note: Azure managed disks are always platform-encrypted by default; the Disk Encryption Set adds **your** key. If platform-managed keys satisfy your compliance requirements, the default AKS StorageClasses already qualify.

Two AKS specifics (both verified in a real deployment):

1. **The cluster's identity needs read access to the Disk Encryption Set**, or PVC provisioning fails with `LinkedAuthorizationFailed … does not have permission to perform 'Microsoft.Compute/diskEncryptionSets/read'`. Grant it once (requires Owner or User Access Administrator rights — a plain Contributor cannot create role assignments):

   ```bash
   az role assignment create --assignee-object-id <cluster-identity-object-id> \
     --assignee-principal-type ServicePrincipal --role Reader \
     --scope <disk-encryption-set-resource-id>
   ```

   Find the identity with `az aks show -g <rg> -n <cluster> --query identity.principalId` (or `servicePrincipalProfile.clientId` for SP-based clusters, then resolve it with `az ad sp show`).

2. **AKS shortcut — no PVC migration needed.** Azure can re-key an existing disk **in place**: scale the database deployment to 0, wait until the disk detaches, then `az disk update --disk-encryption-set <des-id> --encryption-type EncryptionAtRestWithCustomerKey` on the disk behind the PVC (find it via `kubectl get pv <pv-name> -o jsonpath='{.spec.csi.volumeHandle}'`). No data copy, downtime of a few minutes. Caveat: the PVC object still names the old StorageClass — if that PVC is ever deleted and recreated, the new disk silently reverts to platform-managed keys, so still create the encrypted StorageClass for future volumes.

**GCP (GKE, customer-managed key):**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-cmek
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-balanced
  disk-encryption-kms-key: projects/<project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

**On-premise clusters:**
- **Longhorn**: supports encrypted volumes natively (LUKS under the hood) — create a StorageClass with `encrypted: "true"` and the crypto key in a Kubernetes Secret, per the Longhorn documentation.
- **Rook/Ceph**: enable OSD encryption (`encryptedDevice: "true"` in the CephCluster spec) — then *every* volume from that cluster is encrypted at rest.
- **local-path / hostPath provisioners**: encrypt at the node layer instead — put the provisioner's data directory on a LUKS volume on each node (same procedure as the [Docker Compose LUKS walkthrough](#setting-up-an-encrypted-filesystem-with-luks)).

### Migrating an Existing PVC

A PVC's StorageClass cannot be changed in place. Migration = copy the data to a new encrypted PVC, then point the deployment at it. Downtime is the duration of the copy. (On AKS there is a faster in-place alternative — see the Azure notes above.)

> ⚠️ **If a GitOps controller (Flux, Argo CD) manages these Deployments, pause it first** — otherwise it will revert the `--replicas=0` scale-down and restart Postgres **while the copy is running**, corrupting the copy. Suspend reconciliation for the app's manifests before step 2 and resume after step 5. Watch for parent-level reconcilers too: if a root Kustomization/Application re-applies the child objects from git, suspending only the child gets reverted on the next root sync — suspend the parent for the window as well. **Verify the DB pod actually stays gone** (`kubectl get pods -w`) before starting the copy.

> 💡 Before taking any downtime, smoke-test the encrypted StorageClass with a throwaway 1Gi PVC + pod and confirm the provisioned volume reports as encrypted in your storage provider. This surfaces permission problems (like the AKS `LinkedAuthorizationFailed` above) while everything is still running.

```bash
NS=validator   # your namespace

# 1. Create the new encrypted PVC (same size or larger), e.g. data-app-db-pvc-encrypted,
#    with storageClassName set to your encrypted class. Apply it.

# 2. Stop the app so nothing writes during the copy (GitOps paused first — see warning above)
kubectl scale deploy/data-app-backend -n $NS --replicas=0
kubectl scale deploy/data-app-db -n $NS --replicas=0
kubectl wait --for=delete pod -l app=data-app-db -n $NS --timeout=180s

# 3. Copy old PVC -> new PVC with a throwaway pod (exact copy; preserves the capture cursor)
kubectl run pvc-copy -n $NS --restart=Never --image=alpine \
  --overrides='{"spec":{"containers":[{"name":"pvc-copy","image":"alpine","command":["sh","-c","cp -a /from/. /to/ && echo DONE"],"volumeMounts":[{"name":"from","mountPath":"/from","readOnly":true},{"name":"to","mountPath":"/to"}]}],"volumes":[{"name":"from","persistentVolumeClaim":{"claimName":"data-app-db-pvc"}},{"name":"to","persistentVolumeClaim":{"claimName":"data-app-db-pvc-encrypted"}}]}}'
kubectl logs -f pvc-copy -n $NS    # wait for DONE
kubectl delete pod pvc-copy -n $NS

# 4. Point the DB deployment at the new claim
#    (edit deployments.yaml: claimName: data-app-db-pvc-encrypted, then kubectl apply)

# 5. Start and verify
kubectl scale deploy/data-app-db -n $NS --replicas=1
kubectl rollout status deploy/data-app-db -n $NS
kubectl scale deploy/data-app-backend -n $NS --replicas=1

# 6. After verifying (dashboard loads, indexing advances): delete the old
#    unencrypted PVC so the plaintext copy does not linger
kubectl delete pvc data-app-db-pvc -n $NS
```

> Both PVCs are `ReadWriteOnce`; the copy pod mounts both, which works because it is a single pod. If your storage binds volumes to specific nodes, ensure both PVCs are reachable from one node (with `WaitForFirstConsumer` this is normally automatic).

## Backups and Exports

Volume encryption is defeated if a plaintext copy of the data leaves the encrypted volume:

- **Transaction history backups (`BACKUP_S3_*`)** and **exports (`EXPORTS_S3_*`)**: enable server-side encryption on the destination bucket (all major S3-compatible stores support SSE; use SSE-KMS with your own key where available). Restrict bucket access to the credentials the app uses.
- **Ad-hoc `pg_dump`s**: treat any manual dump as sensitive — write it only to encrypted storage and delete it when done.
- **Volume snapshots**: snapshots of an encrypted cloud volume remain encrypted with the same key. Snapshots taken *before* your migration are unencrypted — delete them once the migration is verified.

## Key Management

Where the unlock key lives determines what the encryption is actually worth:

- **Cloud KMS-backed (recommended where available):** AWS KMS / Azure Key Vault / GCP Cloud KMS keys give you rotation, audit logs, and revocation without touching the deployment. Revoking the key is a kill switch: volumes stop attaching and the data becomes unreadable until access is restored.
- **LUKS passphrase / key file:** keep the key file readable by root only (`chmod 400`), **never** on the encrypted volume itself, and keep an offline copy of the passphrase (or a backup of the LUKS header) in your organization's secret store — losing the key means losing the index (recoverable only by re-indexing from the ledger, which is slow but possible since the ledger remains the source of truth). For unattended boot on physical hardware, `clevis` with a TPM is the standard approach.
- **Rotation:** cloud KMS keys rotate transparently. For LUKS, `cryptsetup luksChangeKey` rotates the passphrase without re-encrypting data.

## Verification Checklist

- [ ] **Compose:** `CANTON_DATA_APP_DB_DATA` points into the encrypted mount, and `findmnt -T $CANTON_DATA_APP_DB_DATA` shows the encrypted device (`/dev/mapper/...` for LUKS). `lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT` shows the device as `crypt`.
- [ ] **Kubernetes:** `kubectl get pvc data-app-db-pvc-encrypted -o jsonpath='{.spec.storageClassName}'` returns your encrypted class, and the volume shows as encrypted in your storage provider's console/CLI (e.g. `aws ec2 describe-volumes --query 'Volumes[].Encrypted'`).
- [ ] The app works: dashboard loads, indexing advances after the migration.
- [ ] Old unencrypted volume / PVC / pre-migration snapshots **deleted**.
- [ ] Backup and export buckets have server-side encryption enabled.
- [ ] The unlock key/passphrase is stored in your secret-management system, not on the host, and someone other than the person who set this up can find it.

---

Questions or issues? Contact us through your Noves support channel.
