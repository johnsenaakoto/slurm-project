# Module 06: Shared NFS storage

This module configures the controller as a small NFS server and mounts one
shared directory on both workers. It is intended for learning cluster storage,
not for production hardening.

The controller exports the configured shared path, and each worker mounts it at
the same path. The module then validates that files written from the controller
and both workers are visible from the other nodes.

## Configure

Shared settings live in [`config/cluster.env`](../../config/cluster.env):

```bash
SHARED_STORAGE_PATH="/shared"
NFS_CONTROLLER_PACKAGES="nfs-kernel-server"
NFS_WORKER_PACKAGES="nfs-common"
```

The shared storage path must be an absolute path without spaces.

## Run

From the project root:

```bash
./modules/06-shared-storage/configure-shared-storage.sh
```

Preview the package, export, and mount changes without changing the guests:

```bash
./modules/06-shared-storage/configure-shared-storage.sh --dry-run
```

## Validation

The module verifies:

- NFS packages are installed on the correct nodes
- the controller exports the shared path to both workers
- both workers mount the controller export
- files written from each node are visible through the shared path

This module is a prerequisite for the arrays and dependencies lab because that
lab writes task outputs into shared storage.
