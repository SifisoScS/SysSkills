---
name: Filesystems & Storage Architecture
slug: filesystems-storage-architecture
category: 10-specialized-domains
proficiency: advanced
description: >
  Deep understanding of the Linux Virtual Filesystem (VFS) layer, inode and
  page-cache internals, filesystem design trade-offs (ext4, XFS, Btrfs, ZFS),
  modern async I/O with io_uring, NVMe and SSD storage characteristics,
  distributed filesystems (CephFS, NFS), object storage semantics, and
  Kubernetes CSI dynamic provisioning. Covers observability with eBPF/BCC
  VFS probes and zero-copy I/O patterns.
tags:
  - vfs
  - inode
  - ext4
  - btrfs
  - zfs
  - io-uring
  - page-cache
  - nvme
  - ceph
  - csi
  - kubernetes-storage
status: published
---

## Principles

### 1. The VFS Layer Is the Universal I/O Contract
Every file operation — `open`, `read`, `write`, `fsync` — passes through the
Linux **Virtual Filesystem** layer before reaching a concrete filesystem
implementation. VFS defines a common set of inode, dentry, and file operations
that all filesystems implement. This abstraction means application code is
filesystem-agnostic; the choice of ext4 vs Btrfs vs tmpfs is a deployment
concern, not a code concern.

### 2. The Page Cache Is the Primary Performance Lever
Most I/O does not reach storage. The kernel **page cache** holds recently-read
and recently-written file data in memory. `read()` returns from cache if the
page is present (a cache hit costs ~100 ns); only a miss hits storage (~100 µs
for NVMe, ~10 ms for spinning disk). Write-back caching means `write()` returns
before data reaches persistent storage — `fsync()` is required for durability.
Understanding the page cache is prerequisite to any storage performance work.

### 3. Filesystems Are Optimised for Different Access Patterns
| Filesystem | Optimised for | Key feature |
|---|---|---|
| ext4 | General purpose; small-to-medium files | Journalling (ordered/writeback/journal) |
| XFS | Large files; parallel writes; HPC | Extent-based allocation; scalable B-tree |
| Btrfs | Snapshots; deduplication; RAID | Copy-on-write; subvolumes; send/receive |
| ZFS | Data integrity; pooled storage | Checksums on everything; RAID-Z; ARC |
| tmpfs | In-memory; ephemeral | Backed by RAM + swap; no persistence |
| F2FS | Flash/SSD-optimised | Log-structured; avoids write amplification |

### 4. io_uring Replaces epoll + read/write for High-Throughput I/O
Traditional async I/O (`aio_read`, `epoll`) requires a system call per
operation. `io_uring` (kernel 5.1+) uses a **shared ring buffer** between
kernel and userspace — submissions and completions flow through the ring with
zero system calls in the fast path (`IORING_SETUP_SQPOLL`). For NVMe SSDs with
millions of IOPS, this eliminates system call overhead as the bottleneck.

### 5. Durability Guarantees Require Explicit Flushing
The ordering of `write()` → persistent storage is not guaranteed without
explicit synchronisation. The durability hierarchy:
```
write()         → data in page cache (not durable)
msync(MS_SYNC)  → mmap data flushed to page cache
fdatasync()     → data flushed to storage (no metadata update)
fsync()         → data + metadata flushed (fully durable)
sync_file_range → flush a byte range (avoid full-file fsync)
O_DIRECT        → bypass page cache (application controls buffering)
O_DSYNC         → each write flushed before returning (like fdatasync per write)
```

---

## Implementation Patterns

### Pattern A: Buffered vs Direct I/O Selection
Use buffered I/O (default) for workloads where the kernel's read-ahead and
page-cache can absorb access patterns. Use `O_DIRECT` when the application
implements its own buffer management (databases like PostgreSQL, RocksDB) to
avoid double-buffering and cache pollution.

### Pattern B: Btrfs Subvolumes for Immutable Container Images
Btrfs copy-on-write semantics make subvolume snapshots instantaneous and
space-efficient — Docker's `btrfs` storage driver uses this natively. Each
container layer is a snapshot of the previous, sharing unchanged blocks.

### Pattern C: io_uring Submission Queue Polling
For NVMe storage with submillisecond latency, `IORING_SETUP_SQPOLL` runs a
kernel thread that continuously polls the submission queue — no `io_uring_enter`
syscall needed on the hot path. Reduces per-op overhead from ~500 ns to ~50 ns.

### Pattern D: Kubernetes CSI Dynamic Provisioning
A `StorageClass` references a CSI driver; a `PersistentVolumeClaim` triggers
the CSI driver to create a volume (cloud disk, Ceph RBD, NFS share) and bind
it to the pod. The CSI driver implements three gRPC services: Identity, Node,
Controller.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| `write()` without `fsync()` before ACK | Data loss on crash; "written" data still in page cache | Call `fsync()`/`fdatasync()` before returning success to caller |
| O_DIRECT without aligned buffers | `EINVAL` at runtime; hard to debug | Allocate buffers with `posix_memalign(512)` or `memalign(4096)` |
| Storing many small files in a single directory | `readdir()` scans entire directory; performance degrades past ~100k entries | Shard into subdirectories (first 2 chars of hash as prefix) |
| Using `sync()` (global) instead of `fsync(fd)` | Stalls all I/O on the system; unacceptable latency | Always use per-file `fsync(fd)` or `fdatasync(fd)` |
| tmpfs for persistent data in Kubernetes | Pod restart wipes data; `emptyDir` without `medium: Memory` uses node disk | Use PVC-backed storage for anything that must survive pod restart |
| NFS without `noatime` mount option | Metadata write on every read (`atime` update); throughput halved | Mount with `noatime,nodiratime`; use `relatime` as a compromise |
| Btrfs RAID-5/6 for production | Known data loss bugs under power failure in kernels < 6.6 | Use Btrfs RAID-1/RAID-10 or ZFS RAID-Z for production redundancy |

---

## Code Templates

### Template 1 — C: Buffered vs Direct I/O Comparison
```c
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <unistd.h>

#define FILE_SIZE  (512 * 1024 * 1024LL)   /* 512 MiB */
#define BUF_SIZE   (4 * 1024)               /* 4 KiB */
#define ALIGN      512                       /* required for O_DIRECT */

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

void benchmark_read(const char *path, int use_direct) {
    int flags = O_RDONLY | (use_direct ? O_DIRECT : 0);
    int fd = open(path, flags);
    if (fd < 0) { perror("open"); return; }

    void *buf;
    posix_memalign(&buf, ALIGN, BUF_SIZE);   /* aligned buffer for O_DIRECT */

    /* Drop page cache for fair comparison: echo 1 > /proc/sys/vm/drop_caches */
    double t0 = now_ns();
    ssize_t total = 0, n;
    while ((n = read(fd, buf, BUF_SIZE)) > 0) total += n;
    double elapsed = (now_ns() - t0) / 1e9;

    printf("%s I/O: %.2f MiB/s (%zd bytes in %.3f s)\n",
           use_direct ? "Direct" : "Buffered",
           (double)total / (1024*1024) / elapsed, total, elapsed);

    free(buf);
    close(fd);
}
```

### Template 2 — C: io_uring Async File Read
```c
#include <liburing.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define QUEUE_DEPTH 64
#define BLOCK_SIZE  4096

int iouring_read_file(const char *path) {
    struct io_uring ring;
    /* IORING_SETUP_SQPOLL: kernel thread polls SQ — zero-syscall hot path */
    struct io_uring_params params = { .flags = IORING_SETUP_SQPOLL,
                                       .sq_thread_idle = 2000 /* ms */ };
    if (io_uring_queue_init_params(QUEUE_DEPTH, &ring, &params) < 0) {
        perror("io_uring_queue_init_params");
        return -1;
    }

    int fd = open(path, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return -1; }

    void *buf;
    posix_memalign(&buf, BLOCK_SIZE, BLOCK_SIZE);

    /* Submit read request */
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, BLOCK_SIZE, 0 /* offset */);
    sqe->user_data = 1;                  /* tag for completion matching */
    io_uring_submit(&ring);

    /* Wait for completion */
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    if (cqe->res < 0)
        fprintf(stderr, "io_uring read error: %s\n", strerror(-cqe->res));
    else
        printf("Read %d bytes (user_data=%llu)\n", cqe->res, cqe->user_data);

    io_uring_cqe_seen(&ring, cqe);
    free(buf);
    close(fd);
    io_uring_queue_exit(&ring);
    return 0;
}
```

### Template 3 — Python BCC: VFS Read/Write Latency Histogram
```python
#!/usr/bin/env python3
"""vfs_latency.py — histogram of vfs_read and vfs_write latency per PID."""
from bcc import BPF
import sys, time, signal

PROG = r"""
#include <uapi/linux/ptrace.h>

BPF_HASH(start_read,  u32, u64);
BPF_HASH(start_write, u32, u64);
BPF_HISTOGRAM(read_lat,  u64, 64);
BPF_HISTOGRAM(write_lat, u64, 64);

int trace_vfs_read_entry(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 ts  = bpf_ktime_get_ns();
    start_read.update(&pid, &ts);
    return 0;
}
int trace_vfs_read_return(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *tsp = start_read.lookup(&pid);
    if (!tsp) return 0;
    u64 lat = bpf_ktime_get_ns() - *tsp;
    start_read.delete(&pid);
    read_lat.increment(bpf_log2l(lat));
    return 0;
}
int trace_vfs_write_entry(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 ts  = bpf_ktime_get_ns();
    start_write.update(&pid, &ts);
    return 0;
}
int trace_vfs_write_return(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *tsp = start_write.lookup(&pid);
    if (!tsp) return 0;
    u64 lat = bpf_ktime_get_ns() - *tsp;
    start_write.delete(&pid);
    write_lat.increment(bpf_log2l(lat));
    return 0;
}
"""

b = BPF(text=PROG)
b.attach_kprobe(event="vfs_read",  fn_name="trace_vfs_read_entry")
b.attach_kretprobe(event="vfs_read",  fn_name="trace_vfs_read_return")
b.attach_kprobe(event="vfs_write", fn_name="trace_vfs_write_entry")
b.attach_kretprobe(event="vfs_write", fn_name="trace_vfs_write_return")

print("Tracing VFS read/write latency... Ctrl-C to print histograms")
def print_and_exit(sig, frame):
    print("\n=== VFS Read Latency (ns) ===")
    b["read_lat"].print_log2_hist("latency (ns)")
    print("\n=== VFS Write Latency (ns) ===")
    b["write_lat"].print_log2_hist("latency (ns)")
    sys.exit(0)

import signal
signal.signal(signal.SIGINT, print_and_exit)
while True:
    time.sleep(1)
```

### Template 4 — Rust: Zero-Copy File Serving with `sendfile`
```rust
// zero_copy_server.rs — HTTP file server using sendfile(2) for zero-copy transfer
use std::fs::File;
use std::io::{self, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::io::AsRawFd;

fn send_file(mut conn: TcpStream, path: &str) -> io::Result<()> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    let file_size = metadata.len() as usize;

    // Write HTTP response headers
    write!(conn,
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\n\r\n",
        file_size
    )?;
    conn.flush()?;

    // sendfile(2) — kernel copies from file page cache to socket buffer,
    // never entering user space. Zero allocations, zero copies.
    let conn_fd = conn.as_raw_fd();
    let file_fd = file.as_raw_fd();
    let mut offset: libc::off_t = 0;
    let mut remaining = file_size;

    while remaining > 0 {
        let sent = unsafe {
            libc::sendfile(conn_fd, file_fd, &mut offset, remaining)
        };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        remaining -= sent as usize;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let listener = TcpListener::bind("0.0.0.0:8080")?;
    println!("Serving on :8080");
    for stream in listener.incoming().flatten() {
        let _ = send_file(stream, "/var/www/large_file.bin");
    }
    Ok(())
}
```

### Template 5 — Shell: Btrfs Subvolume Snapshot Management
```bash
#!/usr/bin/env bash
# btrfs_snapshots.sh — create, list, and prune Btrfs snapshots for /data
set -euo pipefail

BTRFS_MOUNT="/btrfs"
DATA_SUBVOL="$BTRFS_MOUNT/data"
SNAP_DIR="$BTRFS_MOUNT/snapshots"
KEEP=7   # retain last 7 daily snapshots

snap_name="data-$(date +%Y%m%d-%H%M%S)"

echo "[1] Creating read-only snapshot: $snap_name"
btrfs subvolume snapshot -r "$DATA_SUBVOL" "$SNAP_DIR/$snap_name"

echo "[2] Current snapshots:"
btrfs subvolume list "$BTRFS_MOUNT" | grep "snapshots/"

echo "[3] Pruning snapshots older than $KEEP most recent..."
mapfile -t snaps < <(
    btrfs subvolume list "$BTRFS_MOUNT" \
    | awk '/snapshots\/data-/{print $NF}' \
    | sort -r
)
for snap in "${snaps[@]:$KEEP}"; do
    echo "  Deleting $snap"
    btrfs subvolume delete "$BTRFS_MOUNT/$snap"
done

# Send incremental snapshot to remote backup
# btrfs send -p "$SNAP_DIR/${snaps[1]}" "$SNAP_DIR/$snap_name" \
#     | ssh backup-host "btrfs receive /backup/data/"

echo "[4] Filesystem usage:"
btrfs filesystem usage "$BTRFS_MOUNT"
```

### Template 6 — Kubernetes: StorageClass + PVC + CSI StatefulSet
```yaml
# storageclass-fast.yaml — Ceph RBD via CSI with WaitForFirstConsumer
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-fast
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ceph-cluster-id        # from ceph fsid
  pool: replicapool
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name:      rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name:       rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace:  rook-ceph
reclaimPolicy: Retain              # keep volume after PVC deletion
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer   # bind when pod is scheduled (NUMA-aware)
---
# statefulset-postgres.yaml — StatefulSet with volumeClaimTemplate
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
      - name: postgres
        image: postgres:16
        env:
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        - name: dshm                # shared memory for parallel query
          mountPath: /dev/shm
      volumes:
      - name: dshm
        emptyDir: { medium: Memory, sizeLimit: 256Mi }
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: ceph-rbd-fast
      resources:
        requests:
          storage: 100Gi
```

---

## Decision Matrix

| Scenario | Filesystem / Storage | Key Config |
|---|---|---|
| General-purpose Linux server | ext4 | `data=ordered`, `barrier=1`, tune `noatime` |
| Large files, parallel writes (HPC, video) | XFS | `allocsize=64m` for large-file pre-allocation |
| Snapshot-heavy (dev environments, CI caches) | Btrfs | `compress=zstd:3`, subvolumes per use case |
| Data integrity critical (backup, archival) | ZFS | `checksum=sha256`, `copies=2`, scheduled scrub |
| High-IOPS database (PostgreSQL, MySQL) | ext4 or XFS with `O_DIRECT` | Disable page cache double-buffering in DB |
| Container image layers | Btrfs or overlayfs | Docker/Podman use overlayfs by default |
| Kubernetes persistent volumes | CSI (Ceph RBD, EBS, GCE PD) | `WaitForFirstConsumer` for NUMA/zone affinity |
| In-memory ephemeral scratch | tmpfs | `emptyDir: {medium: Memory}` in Kubernetes |
| Network-attached shared storage | NFS v4.2 or CephFS | `noatime,nodiratime,rsize=1048576,wsize=1048576` |
| Object storage (S3-compatible) | Ceph RGW, MinIO | Use for immutable blobs; not a POSIX filesystem |

---

## Proficiency Levels

### Novice
- Knows ext4 vs NTFS vs FAT32; understands partitions and mount points
- Runs `df -h`, `du -sh`, `lsblk`, `mount`
- Knows what `fsync` does at a high level
- Understands inodes contain metadata; filenames live in directories

### Intermediate
- Explains the VFS layer and how a `read()` call flows to a filesystem
- Configures ext4 journal modes (`data=ordered` vs `data=writeback`)
- Uses `iostat`, `iotop`, `blktrace` to diagnose I/O bottlenecks
- Creates and mounts Btrfs subvolumes and snapshots
- Configures Kubernetes StorageClass and PersistentVolumeClaim

### Advanced
- Implements `O_DIRECT` I/O with aligned buffers; understands when to bypass page cache
- Writes io_uring programs for high-throughput async file I/O
- Profiles VFS latency with eBPF/BCC (`vfs_read`/`vfs_write` kprobes)
- Configures ZFS pools with RAID-Z, L2ARC read cache, ZIL for sync write acceleration
- Designs Ceph cluster storage classes (SSD pool for hot, HDD for cold) for Kubernetes

### Expert
- Contributes to filesystem kernel code or CSI driver implementations
- Designs storage architecture for 10+ PiB datasets with mixed access patterns
- Implements custom io_uring submission queue polling for sub-50 µs I/O latency
- Architects distributed filesystem topology for multi-region data replication
- Evaluates NVMe-oF (NVMe over Fabrics) and CXL-attached memory for disaggregated storage

---

## AI Prompts

```
You are a Linux storage expert. My PostgreSQL database on ext4 is showing
p99 write latency of 40 ms under heavy OLTP load. Walk me through a
systematic diagnosis: which iostat/blktrace metrics to check, how to
determine if the bottleneck is the kernel page cache, the filesystem journal,
or the underlying NVMe, and what configuration changes to try (mount options,
PostgreSQL checkpointing, O_DIRECT).
```

```
Compare Btrfs, ZFS, and ext4 for a CI/CD build cache use case: 500 GB of
frequently snapshotted build artifacts, deduplication desired, occasional
full-filesystem restore. Consider write performance, snapshot overhead,
deduplication efficiency, and production readiness of each option.
```

```
Explain how io_uring differs from traditional epoll + read/write for a
high-throughput file server. What is IORING_SETUP_SQPOLL and when does it
reduce system call overhead to zero? Show the io_uring lifecycle for a
single file read: SQE preparation, submission, CQE harvesting.
```

```
I need to design Kubernetes storage for a stateful application with three
tiers: hot data (NVMe SSD, < 1 ms latency), warm data (HDD, bulk), and
cold archival (object storage). Design the StorageClass hierarchy, the
Kubernetes API objects needed (PVC, StatefulSet, VolumeSnapshotClass), and
the data lifecycle policy to move data between tiers.
```

---

## References

- **Love, Robert** — *Linux Kernel Development*, Ch. 13 (The Virtual Filesystem)
- **Kerrisk, Michael** — *The Linux Programming Interface*, Ch. 13–15 (File I/O)
- **Linux VFS internals** — `Documentation/filesystems/vfs.rst`
- **io_uring docs** — `Documentation/block/io-uring.rst`; Lord of the io_uring (unixism.net)
- **Btrfs wiki** — https://btrfs.wiki.kernel.org
- **OpenZFS docs** — https://openzfs.github.io/openzfs-docs/
- **Ceph docs** — https://docs.ceph.com — RBD, CephFS, RGW
- **Gregg, Brendan** — *Systems Performance*, Ch. 8 (File Systems); BCC `vfsstat`, `fileslower`
- **NVMe specification** — NVM Express Base Specification 2.0 (nvmexpress.org)
- **Kubernetes CSI** — https://kubernetes-csi.github.io/docs/
- **SysSkills cross-reference** — `os-architecture-foundations`, `memory-management-virtual-memory`,
  `process-scheduling`, `platform-engineering-idp`
