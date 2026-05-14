---
name: Memory Management & Virtual Memory
slug: memory-management-virtual-memory
category: 10-specialized-domains
proficiency: advanced
description: >
  Deep understanding of virtual memory architecture, physical memory management,
  allocator design, and runtime GC strategies. Covers x86-64 paging, slab/buddy
  allocators, huge pages, NUMA, mmap, cgroup v2 memory limits, OOM behaviour,
  and language-level memory safety (Rust ownership, Go sync.Pool, GC tuning).
tags:
  - virtual-memory
  - paging
  - allocators
  - mmap
  - huge-pages
  - numa
  - garbage-collection
  - ebpf
  - rust
  - linux-kernel
status: published
---

## Principles

### 1. Virtual Address Spaces Are Cheap; Physical Pages Are Not
Every process gets a full 48-bit (or 57-bit LA57) virtual address space on
x86-64. The kernel only allocates physical frames on demand via **demand
paging**. Design for **working-set size**, not virtual footprint.

### 2. Four-Level Page Tables Walk Every Access
x86-64 canonical addresses decompose as:
```
[63:48] sign-extension | [47:39] PML4 | [38:30] PDPT | [29:21] PD | [20:12] PT | [11:0] offset
```
Each level is a 4 KiB page of 512 × 8-byte entries. A TLB miss triggers a
hardware page-table walk consuming up to 4 DRAM reads. Keep hot data in
TLB-friendly strides; prefer huge pages for large arrays.

### 3. Allocator Layers Are Composable
```
Application malloc/new
    └─► glibc ptmalloc / jemalloc / tcmalloc (user-space)
            └─► mmap / brk  ──► kernel buddy allocator (order-0..MAX_ORDER)
                                    └─► slab/SLUB (kmalloc, kmem_cache)
```
Each layer amortises system-call cost. Match allocation granularity to layer
capability: per-CPU slab caches for kernel objects, arena allocators for
short-lived workloads, pool allocators for fixed-size objects.

### 4. NUMA Topology Must Be Explicit in HPC and Database Workloads
On multi-socket servers, cross-NUMA memory accesses are 40–100 % slower.
Pin threads with `pthread_setaffinity_np` and allocate memory with
`mbind`/`numa_alloc_onnode`. Kubernetes `topologyManager` policy `single-numa-node`
enforces this at pod level.

### 5. Memory Safety Is a Security Property
Use-after-free, buffer overflows, and double-free are the root cause of ~70 %
of CVEs in C/C++ codebases (Chrome, Linux kernel data). Rust's ownership model
eliminates entire classes at compile time at zero runtime cost. Where C is
required, pair with AddressSanitizer in CI and KASAN in kernel builds.

---

## Implementation Patterns

### Pattern A: Demand Paging with Prefault
Default `mmap(MAP_ANONYMOUS)` faults pages lazily — first write triggers a
page fault. For latency-critical code (e.g., real-time audio, trading engines)
prefault the entire region with `MAP_POPULATE` or `mlock`:
```c
void *buf = mmap(NULL, size, PROT_READ|PROT_WRITE,
                 MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
mlock(buf, size);   // pin in RAM; prevents swap eviction
```

### Pattern B: Huge Pages for High-Throughput Buffers
2 MiB huge pages reduce TLB pressure 512× for the same address range. Use
`MAP_HUGETLB` (explicit) or Transparent Huge Pages (THP) via `madvise`:
```c
madvise(ptr, size, MADV_HUGEPAGE);   // THP hint for kernel
```
For databases (PostgreSQL, ClickHouse) set `vm.nr_hugepages` and allocate with
`libhugetlbfs`. Disable THP `khugepaged` for latency-sensitive services where
background collapse causes jitter.

### Pattern C: Slab Allocator for Fixed-Size Kernel Objects
```c
struct kmem_cache *cache = kmem_cache_create(
    "my_obj", sizeof(struct my_obj), 0,
    SLAB_HWCACHE_ALIGN | SLAB_POISON, NULL);

struct my_obj *obj = kmem_cache_alloc(cache, GFP_KERNEL);
// ... use obj ...
kmem_cache_free(cache, obj);
```
Objects are returned to the per-CPU free-list — subsequent `alloc` paths
are CPU-local and avoid spinlocks on the hot path.

### Pattern D: cgroup v2 Memory Limits and OOM Policy
```
# /sys/fs/cgroup/workload/memory.max   →  hard limit, triggers OOM kill
# /sys/fs/cgroup/workload/memory.high  →  soft limit, throttles allocation
echo "512M" > /sys/fs/cgroup/workload/memory.max
echo "450M" > /sys/fs/cgroup/workload/memory.high
echo "oom_kill_disable=0" > /sys/fs/cgroup/workload/memory.oom.group
```
Kubernetes `resources.limits.memory` maps directly to `memory.max`. Set
`memory.high` ≈ 90 % of limit to get early-warning throttling before OOM.

### Pattern E: NUMA-Aware Allocation in Go
```go
// Use numactl wrapper or libnuma CGO binding.
// At application level, create per-NUMA-node worker pools:
numNodes := numa.MaxNodeID() + 1
pools := make([]*workerPool, numNodes)
for i := range pools {
    node := i
    pools[i] = newWorkerPool(func() {
        numa.RunOnNode(node)          // pin this goroutine's OS thread
    })
}
```

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| `malloc` in hot-path tight loop | Fragmentation, lock contention | Pre-allocate pool; use `sync.Pool` or arena |
| Ignoring NUMA topology in DB | 2× memory latency on cross-socket | `numactl --membind` or NUMA-aware allocator |
| Disabling swap entirely on cloud VMs | OOM kill under burst; no swap-to-SSD grace | Use `zswap` + small swap partition as safety net |
| THP on Redis / latency-sensitive services | Background `khugepaged` causes 10-100 ms stalls | `echo never > /sys/kernel/mm/transparent_hugepage/enabled` |
| `mlock` without `RLIMIT_MEMLOCK` increase | `ENOMEM` at runtime; silent failure in containers | Set `ulimit -l unlimited` or `LimitMEMLOCK=infinity` in systemd unit |
| Go finalizers for resource cleanup | Non-deterministic; GC can delay indefinitely | Use `defer`, `io.Closer`; treat finalizers as last-resort only |
| Pinning every goroutine with `runtime.LockOSThread` | Exhausts OS thread pool; increases scheduler overhead | Only pin goroutines that call `numa_*` or `mlock` syscalls |
| Over-committing without `vm.overcommit_ratio` tuning | Random OOM kills under load spikes | Set `vm.overcommit_memory=2`; size ratio to physical RAM |

---

## Code Templates

### Template 1 — C: Custom Slab (Pool) Allocator
```c
/* pool.h — fixed-size object pool, lock-free with atomic free-list */
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct pool_node { struct pool_node *next; } pool_node_t;

typedef struct {
    _Atomic(pool_node_t*) head;
    size_t   obj_size;
    char    *arena;
    size_t   capacity;
} pool_t;

pool_t* pool_create(size_t obj_size, size_t count) {
    pool_t *p = malloc(sizeof(*p));
    size_t stride = obj_size > sizeof(pool_node_t) ? obj_size : sizeof(pool_node_t);
    p->arena    = aligned_alloc(64, stride * count);
    p->obj_size = stride;
    p->capacity = count;
    atomic_store(&p->head, NULL);
    /* push all slots onto free-list */
    for (size_t i = 0; i < count; i++) {
        pool_node_t *node = (pool_node_t*)(p->arena + stride * i);
        pool_node_t *old;
        do { old = atomic_load(&p->head); node->next = old; }
        while (!atomic_compare_exchange_weak(&p->head, &old, node));
    }
    return p;
}

void* pool_alloc(pool_t *p) {
    pool_node_t *old, *next;
    do {
        old = atomic_load(&p->head);
        if (!old) return NULL;   /* pool exhausted */
        next = old->next;
    } while (!atomic_compare_exchange_weak(&p->head, &old, next));
    memset(old, 0, p->obj_size);
    return old;
}

void pool_free(pool_t *p, void *ptr) {
    pool_node_t *node = ptr, *old;
    do { old = atomic_load(&p->head); node->next = old; }
    while (!atomic_compare_exchange_weak(&p->head, &old, node));
}
```

### Template 2 — Rust: Arena Allocator with Typed Bump Allocation
```rust
// Requires: bumpalo = "3"
use bumpalo::Bump;

pub struct RequestArena {
    bump: Bump,
}

impl RequestArena {
    pub fn new() -> Self {
        Self { bump: Bump::with_capacity(64 * 1024) }   // 64 KiB initial
    }

    pub fn alloc<T>(&self, val: T) -> &mut T {
        self.bump.alloc(val)
    }

    pub fn alloc_slice_copy<T: Copy>(&self, src: &[T]) -> &[T] {
        self.bump.alloc_slice_copy(src)
    }
}
// Arena is dropped at end of request; all allocations freed in O(1).
// Zero fragmentation — bump pointer resets to base on drop.

// Usage in an Actix-Web handler:
async fn handle(req: web::Json<Payload>) -> impl Responder {
    let arena = RequestArena::new();
    let name: &str = arena.alloc_slice_copy(req.name.as_bytes())
                          .as_ref()
                          .map(|b| std::str::from_utf8(b).unwrap())
                          .unwrap_or_default();
    // `name` lives until end of this function scope — no heap allocation
    web::Json(serde_json::json!({ "echo": name }))
}
```

### Template 3 — Go: `sync.Pool` for Zero-GC Hot Path
```go
package bufpool

import (
    "bytes"
    "sync"
)

var pool = sync.Pool{
    New: func() any { return bytes.NewBuffer(make([]byte, 0, 4096)) },
}

// Get returns a reset buffer from the pool.
func Get() *bytes.Buffer {
    b := pool.Get().(*bytes.Buffer)
    b.Reset()
    return b
}

// Put returns buf to the pool. Do NOT use buf after calling Put.
func Put(buf *bytes.Buffer) {
    if buf.Cap() > 1<<20 { // discard oversized buffers (>1 MiB)
        return
    }
    pool.Put(buf)
}

// Example: JSON marshal without heap allocation per request
func MarshalResponse(v any) ([]byte, error) {
    buf := Get()
    defer Put(buf)
    enc := json.NewEncoder(buf)
    if err := enc.Encode(v); err != nil {
        return nil, err
    }
    result := make([]byte, buf.Len())
    copy(result, buf.Bytes())
    return result, nil
}
```

### Template 4 — eBPF/BCC: Page Fault Profiler (Python)
```python
#!/usr/bin/env python3
"""page_faults.py — profile minor/major page faults per PID using BCC."""
from bcc import BPF
import sys, time

PROG = r"""
#include <uapi/linux/ptrace.h>
#include <linux/mm.h>

BPF_HASH(minor_faults, u32, u64);
BPF_HASH(major_faults, u32, u64);

int trace_minor(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *cnt = minor_faults.lookup_or_try_init(&pid, &(u64){0});
    if (cnt) (*cnt)++;
    return 0;
}

int trace_major(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *cnt = major_faults.lookup_or_try_init(&pid, &(u64){0});
    if (cnt) (*cnt)++;
    return 0;
}
"""

b = BPF(text=PROG)
b.attach_kprobe(event="handle_mm_fault", fn_name="trace_minor")
# Major faults enter do_page_fault -> handle_mm_fault with VM_FAULT_MAJOR flag
# For simplicity we probe __do_page_fault (x86-64 kernel ≤ 5.14)
try:
    b.attach_kprobe(event="__do_page_fault", fn_name="trace_major")
except Exception:
    pass  # kernel version differences

target_pid = int(sys.argv[1]) if len(sys.argv) > 1 else 0
print(f"Profiling page faults {'for PID '+str(target_pid) if target_pid else 'system-wide'}. Ctrl-C to stop.")

try:
    time.sleep(10)
except KeyboardInterrupt:
    pass

print(f"\n{'PID':>8}  {'MINOR':>10}  {'MAJOR':>10}")
for pid, cnt in sorted(b["minor_faults"].items(), key=lambda x: -x[1].value):
    if target_pid and pid.value != target_pid:
        continue
    maj = b["major_faults"].get(pid, None)
    maj_val = maj.value if maj else 0
    print(f"{pid.value:>8}  {cnt.value:>10}  {maj_val:>10}")
```

### Template 5 — C: mmap File-Backed Buffer with Huge Pages
```c
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

/* Map a file into memory; hint kernel to back with 2 MiB huge pages */
void* mmap_file_hugepage(const char *path, size_t *out_size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;

    *out_size = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);

    void *addr = mmap(NULL, *out_size,
                      PROT_READ,
                      MAP_PRIVATE | MAP_POPULATE,   /* fault-in all pages at mmap time */
                      fd, 0);
    close(fd);
    if (addr == MAP_FAILED) return NULL;

    /* Advise THP (requires CONFIG_TRANSPARENT_HUGEPAGE=y) */
    madvise(addr, *out_size, MADV_HUGEPAGE);
    /* Sequential scan pattern — disable readahead speculation */
    madvise(addr, *out_size, MADV_SEQUENTIAL);

    return addr;
}

void mmap_release(void *addr, size_t size) {
    munmap(addr, size);
}
```

### Template 6 — Go: GC Tuning for Low-Latency Services
```go
package main

import (
    "runtime"
    "runtime/debug"
    _ "net/http/pprof"   // expose /debug/pprof/heap
    "net/http"
)

func init() {
    // GOGC=200 → GC fires when live heap doubles (default 100).
    // Reduces GC frequency at cost of peak RSS. Trade off per workload.
    debug.SetGCPercent(200)

    // GOMEMLIMIT caps total Go memory (Go 1.19+). Prevents OOM without
    // aggressive GC. Set to ~80% of container memory.limit.
    debug.SetMemoryLimit(400 << 20) // 400 MiB

    // For ultra-low latency (trading, game servers): tune GOMAXPROCS
    // to leave one CPU free for GC mark phase.
    runtime.GOMAXPROCS(runtime.NumCPU() - 1)
}

// Expose pprof heap endpoint for continuous profiling.
func startPprofServer() {
    go http.ListenAndServe(":6060", nil)
}

// Heap allocation rate monitor — emit metric for Prometheus.
func heapAllocRate() float64 {
    var ms runtime.MemStats
    runtime.ReadMemStats(&ms)
    return float64(ms.HeapAlloc) / float64(ms.HeapSys)
}
```

---

## Decision Matrix

| Scenario | Recommended Approach | Rationale |
|---|---|---|
| Fixed-size objects, high allocation rate (kernel driver) | Slab / kmem_cache | Per-CPU free-list, zero fragmentation |
| Large sequential buffers (ML inference, video decode) | `mmap` + `MAP_POPULATE` + `MADV_HUGEPAGE` | Avoids `malloc` overhead; huge pages cut TLB misses |
| Request-scoped short-lived objects (web handler) | Bump arena (bumpalo / monotonic allocator) | O(1) alloc+free, zero fragmentation, cache-friendly |
| Shared objects across goroutines (pool of DB connections) | `sync.Pool` | GC-aware; objects reclaimed between GC cycles |
| Multi-socket server, DB/in-memory cache | NUMA-bound allocation (`mbind`, `numa_alloc_onnode`) | Halves cross-NUMA latency on EPYC/Xeon |
| Container with memory limit | `GOMEMLIMIT` + cgroup `memory.high` | Avoids OOM kill; soft throttling before hard limit |
| Latency-critical service, Redis-like | Disable THP (`echo never`) | Eliminates `khugepaged` stall spikes |
| Kernel module, trusted code path | `vmalloc` for large virtually-contiguous | `kmalloc` limited to 4 MiB; `vmalloc` maps non-contiguous physical pages |
| Debug / ASAN in CI | `-fsanitize=address` (C/C++) or KASAN (kernel) | Detects heap overflow, UAF, double-free at test time |

---

## Proficiency Levels

### Novice
- Understands heap vs stack; knows `malloc`/`free` and GC concepts
- Can read `/proc/meminfo`, `free -h`
- Writes basic `mmap` file read

### Intermediate
- Explains 4-level page tables and TLB shootdowns
- Configures `vm.swappiness`, `overcommit_memory`, `dirty_ratio`
- Uses `valgrind --leak-check` and `pmap` to diagnose leaks
- Implements `sync.Pool` in Go; understands GC pressure

### Advanced
- Designs slab or arena allocators for production C/Rust services
- Profiles page faults with eBPF; traces `kmem_cache_alloc` call stacks
- Tunes NUMA affinity with `numactl`; interprets `numastat`
- Configures cgroup v2 `memory.high`/`memory.max` and understands OOM score
- Writes KASAN-clean kernel modules

### Expert
- Implements a buddy allocator or region-based GC from scratch
- Designs CXL (Compute Express Link) memory tiering for hot/warm/cold data
- Contributes to Linux `mm/` subsystem; understands `folio` migration in 6.x+
- Evaluates confidential memory (AMD SME, Intel TME) for data-in-use encryption
- Tunes JVM ZGC / Shenandoah for sub-1 ms GC pause SLOs

---

## AI Prompts

```
You are a Linux kernel memory subsystem expert.
Explain how the buddy allocator handles order-0 page allocation under memory
pressure and describe what happens when the zone's free list is exhausted.
Include mention of kswapd, direct reclaim, and OOM killer invocation order.
```

```
Acting as a performance engineer: I have a Go service consuming 6 GiB RSS with
a 4 GiB container limit. GC pause histogram shows p99 = 180 ms. The service
processes 50,000 JSON requests per second. Suggest a step-by-step investigation
plan: which pprof profiles to capture, which GOGC/GOMEMLIMIT settings to try,
and how to identify the allocation site causing heap pressure.
```

```
Compare jemalloc, tcmalloc, and mimalloc for a multi-threaded C++ service doing
mixed small (16-128 byte) and medium (4-64 KiB) allocations at 500k alloc/s.
Explain arena-per-thread strategies, fragmentation characteristics, and how each
integrates with Linux huge pages.
```

```
I need a Rust allocator that satisfies GlobalAlloc for a no_std embedded target
(Cortex-M4, 256 KiB SRAM). Design a bitmap-based fixed-block allocator supporting
block sizes 16/32/64/128 bytes. Show the data structure and alloc/dealloc logic.
```

```
Explain the sequence of kernel events when a userspace process writes to an
anonymous mmap page for the first time. Walk from the CPU page fault exception
vector through do_page_fault, handle_mm_fault, __anon_vma, and page table fill,
ending with the TLB load.
```

---

## References

- **Love, Robert** — *Linux Kernel Development*, Ch. 12 (Memory Management)
- **Gorman, Mel** — *Understanding the Linux Virtual Memory Manager* (free PDF)
- **Linux mm/ source** — `mm/slab.c`, `mm/buddy.c`, `mm/mmap.c`
- **Intel SDM Vol. 3A** — Ch. 4 (Paging) — 4-level and 5-level page tables
- **bumpalo crate** — https://docs.rs/bumpalo — Rust arena allocator
- **Go runtime GC guide** — https://tip.golang.org/doc/gc-guide
- **NUMA memory policy** — `man 2 mbind`, `man 3 numa`
- **BCC tools** — `memleak`, `mmapsnoop`, `drsnoop` in bcc/tools/
- **Google TCMalloc** — https://google.github.io/tcmalloc/design.html
- **jemalloc internals** — https://jemalloc.net/jemalloc.3.html
- **CXL memory tiering** — LWN: "Memory tiering with CXL" (2023)
- **KASAN docs** — Documentation/dev-tools/kasan.rst in kernel tree
