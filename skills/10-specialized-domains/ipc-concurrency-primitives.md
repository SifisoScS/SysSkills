---
name: IPC & Concurrency Primitives
slug: ipc-concurrency-primitives
category: 10-specialized-domains
proficiency: advanced
description: >
  Master inter-process communication mechanisms (pipes, POSIX shared memory,
  message queues, Unix domain sockets) and concurrency primitives (mutexes,
  condition variables, semaphores, futex, read-write locks, barriers). Covers
  the C11/C++11 memory model and atomic ordering guarantees, lock-free data
  structures (SPSC/MPSC ring buffers), the ABA problem, Go channel internals
  and the happens-before model, and Rust's ownership-based data-race
  elimination. Includes practical patterns for high-throughput inter-thread
  and inter-process communication on Linux.
tags:
  - ipc
  - shared-memory
  - posix-mq
  - unix-sockets
  - mutex
  - condition-variable
  - futex
  - lock-free
  - atomics
  - memory-model
  - go-channels
  - rust-concurrency
status: published
---

## Principles

### 1. IPC Mechanisms Form a Latency-Bandwidth Hierarchy
Choose the mechanism that matches the communication pattern:
```
Fastest ◄─────────────────────────────────────────────► Most Flexible
  Shared memory    Pipes/FIFOs    POSIX MQ    Unix sockets    TCP sockets
  ~50 ns           ~1 µs          ~2 µs        ~3 µs           ~10+ µs
  (same host)      (kernel copy)  (kernel buf) (kernel copy)   (loopback)
```
Shared memory has the lowest latency because the kernel makes no copy — both
processes map the same physical pages. The cost is explicit synchronisation.
Unix domain sockets trade a kernel copy for a clean file-descriptor API with
`select`/`epoll` integration. Choose based on the latency budget and whether
the processes need to be decoupled or tightly coupled.

### 2. Synchronisation Must Match the Data Structure's Invariants
A mutex protects a critical section — the invariant is that only one thread
executes it at a time. A condition variable solves the **producer-consumer**
problem — the invariant is "don't consume until there is something to consume".
A read-write lock optimises for **read-heavy** workloads — many concurrent
readers, exclusive writers. Semaphores count available resources. Using the
wrong primitive adds unnecessary contention or introduces correctness bugs.

### 3. The Linux Futex Is the Kernel Primitive Under Everything
`pthread_mutex_lock`, `sem_wait`, Go's `sync.Mutex` — all compile down to the
Linux **futex** (fast userspace mutex) syscall. In the uncontended case
(common), a futex operation is a single atomic compare-and-swap in userspace
with **no syscall**. The syscall only fires when a thread must actually sleep
(contended case). Understanding futex explains why uncontended mutexes are
essentially free (~10 ns) while contended mutexes are expensive (~1–5 µs,
due to the context switch).

### 4. The Memory Model Defines What "Visibility" Means Across Threads
Without memory-ordering constraints, CPUs and compilers reorder loads and
stores freely for performance. The C11/C++11/Go/Rust memory models define
**happens-before** relationships:
- `memory_order_relaxed` — no ordering; safe only for counters with no
  dependent reads
- `memory_order_release` / `memory_order_acquire` — release a "store" that
  becomes visible to a thread that "acquires" the same atomic
- `memory_order_seq_cst` — total sequential order across all threads; most
  expensive; default for `std::atomic`

Using `relaxed` where `acquire/release` is required is a data race even if
no crash occurs in testing — the bug surfaces under a different CPU
microarchitecture or compiler optimisation level.

### 5. Lock-Free Does Not Mean Wait-Free, and Neither Means "No Bugs"
**Lock-free**: at least one thread always makes progress (no deadlock). A
contending thread may spin but never blocks indefinitely.
**Wait-free**: every thread completes in a bounded number of steps regardless
of contention.
Lock-free structures are hard to get right: the **ABA problem** (a pointer
looks unchanged but the pointed-to object was freed and reallocated at the
same address), memory reclamation (hazard pointers, epoch-based reclamation),
and spurious CAS failures under high contention. Use a battle-tested library
(`crossbeam` in Rust, `folly` in C++) before rolling your own.

### 6. Go Channels and Rust Ownership Eliminate Entire Bug Classes
Go's channel model enforces that data is passed between goroutines — not
shared simultaneously. The Go memory model guarantees that a send on a channel
**happens-before** the corresponding receive completes, so no extra
synchronisation is needed for data passed through a channel. Rust's ownership
system makes shared mutable state a **compile-time error** — a value behind
`Arc<Mutex<T>>` can only be mutated by the thread holding the lock, enforced
by the type system, not by convention.

---

## Implementation Patterns

### Pattern A: POSIX Shared Memory + Semaphore for Zero-Copy IPC
Map the same file into two processes with `shm_open` + `mmap`. Use a named
POSIX semaphore (or a `pthread_mutex` with `PTHREAD_PROCESS_SHARED`) for
mutual exclusion across process boundaries.

### Pattern B: Single-Producer Single-Consumer (SPSC) Lock-Free Ring Buffer
Power-of-two sized ring; producer owns `write_pos`, consumer owns `read_pos`.
Both are cache-line-padded atomics to avoid false sharing. The producer stores
with `release` ordering; the consumer loads with `acquire` — establishing the
happens-before that makes the data visible without a mutex.

### Pattern C: Condition Variable for Producer-Consumer Queuing
`pthread_cond_wait` atomically releases the mutex and sleeps — avoiding the
lost-wakeup race that naive sleep-then-check code has. The loop
`while (!condition) cond_wait(...)` guards against spurious wakeups.

### Pattern D: Go Fan-Out / Fan-In Pipeline
Chain goroutines with channels: each stage reads from an input channel,
transforms data, and writes to an output channel. `sync.WaitGroup` gates the
final stage. Closing the input channel is the clean shutdown signal — `range`
over a channel exits when the channel is closed.

### Pattern E: Rust `crossbeam` for MPMC Queues
`crossbeam_channel::bounded(N)` creates a multi-producer multi-consumer bounded
channel backed by a lock-free queue. Blocking `send`/`recv` and non-blocking
`try_send`/`try_recv` are available. Rust's borrow checker ensures no data
races on the values sent through the channel.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Mutex held across I/O or syscall | Contended mutex blocks all other threads for the I/O duration | Move I/O outside the critical section; use a local copy pattern |
| Spurious wakeup not handled (`if` instead of `while` on cond_wait) | Threads wake up before condition is true; corrupt state | Always loop: `while (!ready) pthread_cond_wait(...)` |
| `memory_order_relaxed` on flag used as synchronisation signal | Flag update invisible to another thread; data race | Use `release` on the store and `acquire` on the load |
| False sharing — two atomics on the same cache line | Both cores fight for the same cache line; throughput collapses | Pad each hot atomic to its own 64-byte cache line |
| Unlocking in a different thread than the one that locked | Undefined behaviour with POSIX mutexes; crashes with `EPERM` | Mutexes must be unlocked by the owning thread; use semaphores for cross-thread release |
| ABA problem in CAS-based lock-free code | CAS succeeds on a pointer that changed and was reused; heap corruption | Use tagged pointers (version counter) or hazard pointers / epoch-based reclamation |
| Unbuffered Go channel used for high-frequency signalling | Every send blocks until a receiver is ready; goroutine scheduling overhead ~1 µs per signal | Use a buffered channel or a shared atomic flag for polling-style hot loops |
| `sync.Mutex` protecting large objects copied on every lock | Lock contention AND heap allocation on every critical section | Pass a pointer; lock only the mutation, not the read |

---

## Code Templates

### Template 1 — C: POSIX Shared Memory + Process-Shared Mutex & Condvar
```c
/* shm_producer.c — writes messages into shared memory; shm_consumer.c reads */
#define _GNU_SOURCE
#include <fcntl.h>
#include <sys/mman.h>
#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define SHM_NAME   "/myapp_shm"
#define MSG_LEN    128
#define RING_SIZE  16

typedef struct {
    pthread_mutex_t lock;      /* PTHREAD_PROCESS_SHARED mutex */
    pthread_cond_t  not_empty; /* signal: data available       */
    pthread_cond_t  not_full;  /* signal: space available      */
    int head, tail, count;
    char msgs[RING_SIZE][MSG_LEN];
} shared_ring_t;

shared_ring_t* shm_create(void) {
    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0600);
    ftruncate(fd, sizeof(shared_ring_t));
    shared_ring_t *shm = mmap(NULL, sizeof(*shm),
                               PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    pthread_mutexattr_t mattr;
    pthread_mutexattr_init(&mattr);
    pthread_mutexattr_setpshared(&mattr, PTHREAD_PROCESS_SHARED);
    pthread_mutex_init(&shm->lock, &mattr);

    pthread_condattr_t cattr;
    pthread_condattr_init(&cattr);
    pthread_condattr_setpshared(&cattr, PTHREAD_PROCESS_SHARED);
    pthread_cond_init(&shm->not_empty, &cattr);
    pthread_cond_init(&shm->not_full,  &cattr);

    shm->head = shm->tail = shm->count = 0;
    return shm;
}

void shm_produce(shared_ring_t *shm, const char *msg) {
    pthread_mutex_lock(&shm->lock);
    while (shm->count == RING_SIZE)           /* wait for space */
        pthread_cond_wait(&shm->not_full, &shm->lock);
    strncpy(shm->msgs[shm->tail], msg, MSG_LEN - 1);
    shm->tail  = (shm->tail + 1) % RING_SIZE;
    shm->count++;
    pthread_cond_signal(&shm->not_empty);
    pthread_mutex_unlock(&shm->lock);
}

void shm_consume(shared_ring_t *shm, char *out) {
    pthread_mutex_lock(&shm->lock);
    while (shm->count == 0)                   /* wait for data */
        pthread_cond_wait(&shm->not_empty, &shm->lock);
    strncpy(out, shm->msgs[shm->head], MSG_LEN);
    shm->head  = (shm->head + 1) % RING_SIZE;
    shm->count--;
    pthread_cond_signal(&shm->not_full);
    pthread_mutex_unlock(&shm->lock);
}
```

### Template 2 — C: Lock-Free SPSC Ring Buffer (Atomic Acquire/Release)
```c
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

#define RING_POW2  10               /* 2^10 = 1024 slots */
#define RING_MASK  ((1 << RING_POW2) - 1)
#define CACHE_LINE 64

typedef struct {
    /* Pad each position to its own cache line to prevent false sharing */
    _Alignas(CACHE_LINE) _Atomic size_t write_pos;
    _Alignas(CACHE_LINE) _Atomic size_t read_pos;
    _Alignas(CACHE_LINE) void   *slots[1 << RING_POW2];
} spsc_ring_t;

static inline spsc_ring_t* spsc_create(void) {
    spsc_ring_t *r = aligned_alloc(CACHE_LINE, sizeof(spsc_ring_t));
    atomic_store_explicit(&r->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&r->read_pos,  0, memory_order_relaxed);
    return r;
}

/* Producer — only one thread calls this */
static inline bool spsc_push(spsc_ring_t *r, void *item) {
    size_t wp = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
    size_t rp = atomic_load_explicit(&r->read_pos,  memory_order_acquire);
    if (wp - rp >= (1 << RING_POW2))
        return false;   /* full */
    r->slots[wp & RING_MASK] = item;
    /* release: make the slot write visible before advancing write_pos */
    atomic_store_explicit(&r->write_pos, wp + 1, memory_order_release);
    return true;
}

/* Consumer — only one thread calls this */
static inline void* spsc_pop(spsc_ring_t *r) {
    size_t rp = atomic_load_explicit(&r->read_pos,  memory_order_relaxed);
    size_t wp = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    if (rp == wp)
        return NULL;    /* empty */
    void *item = r->slots[rp & RING_MASK];
    /* release: let producer see the updated read_pos */
    atomic_store_explicit(&r->read_pos, rp + 1, memory_order_release);
    return item;
}
```

### Template 3 — Go: Fan-Out / Fan-In Pipeline with Cancellation
```go
package pipeline

import (
    "context"
    "sync"
)

// generator emits work items onto an output channel; closes it when done or ctx cancelled.
func generator(ctx context.Context, items []string) <-chan string {
    out := make(chan string, len(items))
    go func() {
        defer close(out)
        for _, item := range items {
            select {
            case <-ctx.Done():
                return
            case out <- item:
            }
        }
    }()
    return out
}

// worker processes items from in and sends results to out.
func worker(ctx context.Context, id int, in <-chan string, out chan<- string) {
    for item := range in {
        select {
        case <-ctx.Done():
            return
        case out <- process(item):  // process is domain-specific transform
        }
    }
}

// fanOut spawns n workers all reading from the same input channel.
func fanOut(ctx context.Context, in <-chan string, n int) []<-chan string {
    outs := make([]<-chan string, n)
    for i := range outs {
        ch := make(chan string, 64)
        outs[i] = ch
        go worker(ctx, i, in, ch)
    }
    return outs
}

// merge (fan-in) drains multiple channels into one.
func merge(ctx context.Context, cs []<-chan string) <-chan string {
    out := make(chan string, 256)
    var wg sync.WaitGroup
    wg.Add(len(cs))
    for _, c := range cs {
        c := c
        go func() {
            defer wg.Done()
            for item := range c {
                select {
                case <-ctx.Done():
                    return
                case out <- item:
                }
            }
        }()
    }
    go func() { wg.Wait(); close(out) }()
    return out
}

func process(s string) string { return "[" + s + "]" } // placeholder

// Run ties the pipeline together: generator → fan-out (4 workers) → fan-in → collect.
func Run(ctx context.Context, items []string) []string {
    src     := generator(ctx, items)
    workers := fanOut(ctx, src, 4)
    results := merge(ctx, workers)

    var out []string
    for r := range results {
        out = append(out, r)
    }
    return out
}
```

### Template 4 — Rust: `Arc<Mutex<T>>` vs `crossbeam` vs `Rayon`
```rust
// Demonstrates three concurrency patterns in Rust.
use std::sync::{Arc, Mutex};
use std::thread;

// --- Pattern A: Shared mutable state with Arc<Mutex<T>> ---
fn shared_counter() {
    let counter = Arc::new(Mutex::new(0u64));
    let mut handles = vec![];

    for _ in 0..8 {
        let c = Arc::clone(&counter);
        handles.push(thread::spawn(move || {
            let mut val = c.lock().unwrap();
            *val += 1;
            // lock released automatically when `val` drops at end of scope
        }));
    }
    for h in handles { h.join().unwrap(); }
    println!("counter = {}", *counter.lock().unwrap());
}

// --- Pattern B: MPMC channel with crossbeam ---
// Cargo.toml: crossbeam = "0.8"
fn channel_pipeline() {
    use crossbeam_channel::bounded;
    let (tx, rx) = bounded::<String>(64);

    // Spawn producer
    let tx2 = tx.clone();
    thread::spawn(move || {
        for i in 0..100 {
            tx2.send(format!("item-{}", i)).unwrap();
        }
        drop(tx2); // close sender so receivers know we're done
    });
    drop(tx);

    // Spawn consumer threads
    let mut handles = vec![];
    for _ in 0..4 {
        let rx2 = rx.clone();
        handles.push(thread::spawn(move || {
            for msg in rx2 { // iterates until channel closed
                println!("consumed: {}", msg);
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
}

// --- Pattern C: Data parallelism with Rayon (work-stealing thread pool) ---
// Cargo.toml: rayon = "1"
fn parallel_map() {
    use rayon::prelude::*;
    let data: Vec<u64> = (0..1_000_000).collect();
    // par_iter uses a work-stealing thread pool (one thread per CPU)
    let sum: u64 = data.par_iter().map(|&x| x * x).sum();
    println!("sum of squares = {}", sum);
}
```

### Template 5 — C: POSIX Message Queue with `mq_notify` Async Receive
```c
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define MQ_NAME   "/myapp_mq"
#define MSG_SIZE  256
#define MAX_MSGS  10

static mqd_t mq;

/* Called in a new thread when a message arrives (SA_SIGACTION + SIGEV_THREAD) */
static void on_message(union sigval sv) {
    char buf[MSG_SIZE + 1];
    ssize_t n = mq_receive(mq, buf, MSG_SIZE, NULL);
    if (n > 0) {
        buf[n] = '\0';
        printf("Received: %s\n", buf);
    }
    /* Re-arm the notification — it is one-shot */
    struct sigevent sev = {
        .sigev_notify           = SIGEV_THREAD,
        .sigev_notify_function  = on_message,
        .sigev_value.sival_ptr  = NULL,
    };
    mq_notify(mq, &sev);
}

mqd_t mq_create_consumer(void) {
    struct mq_attr attr = {
        .mq_flags   = 0,
        .mq_maxmsg  = MAX_MSGS,
        .mq_msgsize = MSG_SIZE,
    };
    mq = mq_open(MQ_NAME, O_CREAT | O_RDONLY | O_NONBLOCK, 0600, &attr);
    if (mq == (mqd_t)-1) { perror("mq_open"); exit(1); }

    struct sigevent sev = {
        .sigev_notify          = SIGEV_THREAD,
        .sigev_notify_function = on_message,
    };
    mq_notify(mq, &sev);
    return mq;
}

void mq_produce(const char *msg) {
    mqd_t prod = mq_open(MQ_NAME, O_WRONLY);
    if (mq_send(prod, msg, strlen(msg), 0) < 0)
        perror("mq_send");
    mq_close(prod);
}

void mq_cleanup(void) {
    mq_close(mq);
    mq_unlink(MQ_NAME);
}
```

### Template 6 — Python: `multiprocessing.shared_memory` for Zero-Copy IPC
```python
"""shared_mem_ipc.py — NumPy array shared across processes via shared_memory.
   No pickling, no copying — both processes read/write the same physical pages.
"""
from multiprocessing import Process, shared_memory, Semaphore
import numpy as np
import time

SHAPE = (1000, 1000)
DTYPE = np.float64

def producer(shm_name: str, sem_ready: Semaphore, sem_done: Semaphore) -> None:
    # Attach to the existing shared memory block
    existing = shared_memory.SharedMemory(name=shm_name)
    arr = np.ndarray(SHAPE, dtype=DTYPE, buffer=existing.buf)

    for i in range(5):
        arr[:] = float(i)          # write directly into shared pages
        sem_ready.release()        # signal consumer: data ready
        sem_done.acquire()         # wait for consumer to finish reading
        print(f"Producer: wrote frame {i}")

    existing.close()

def consumer(shm_name: str, sem_ready: Semaphore, sem_done: Semaphore) -> None:
    existing = shared_memory.SharedMemory(name=shm_name)
    arr = np.ndarray(SHAPE, dtype=DTYPE, buffer=existing.buf)

    for _ in range(5):
        sem_ready.acquire()        # wait for producer
        total = arr.sum()          # zero-copy read
        print(f"Consumer: sum = {total:.0f}")
        sem_done.release()         # signal producer: reading done

    existing.close()

if __name__ == "__main__":
    # Allocate shared memory in the parent
    shm = shared_memory.SharedMemory(create=True, size=np.dtype(DTYPE).itemsize * int(np.prod(SHAPE)))

    sem_ready = Semaphore(0)
    sem_done  = Semaphore(0)

    p = Process(target=producer, args=(shm.name, sem_ready, sem_done))
    c = Process(target=consumer, args=(shm.name, sem_ready, sem_done))
    p.start(); c.start()
    p.join();  c.join()

    shm.close()
    shm.unlink()
```

---

## Decision Matrix

| Scenario | Mechanism | Rationale |
|---|---|---|
| Same-process, single producer, single consumer, < 1 µs target | Lock-free SPSC ring buffer | No syscall; acquire/release atomics; ~50 ns per op |
| Same-process, multi-producer multi-consumer | `crossbeam` bounded channel (Rust) or Go buffered channel | Battle-tested MPMC; safe memory reclamation |
| Cross-process, same host, large data (video frames, ML tensors) | POSIX shared memory + semaphore/mutex | Zero-copy; semaphore for synchronisation across process boundary |
| Cross-process, same host, small messages, event-driven | POSIX message queue with `mq_notify` | Async notification; no polling; bounded queue prevents overflow |
| Cross-process, same host, stream (logging, shell pipe) | Unix domain socket or named FIFO | FIFO for one-directional stream; Unix socket for bidirectional |
| Cross-host communication | TCP socket (or gRPC/HTTP) | Only option; match to existing RPC framework |
| Read-heavy shared config in-process | `pthread_rwlock` or `RwLock<T>` (Rust) | Multiple concurrent readers; exclusive writer |
| Periodic work notification between threads | Condition variable + mutex | Avoids busy-polling; spurious wakeup handled by `while` loop |
| Data parallelism (CPU-bound batch processing) | Rayon (Rust) or `go` + `WaitGroup` | Work-stealing pool; no manual thread management |
| Real-time constraint, no blocking allowed | Lock-free SPSC or MPSC; pre-allocated pool | Mutex contention introduces unpredictable latency spikes |

---

## Proficiency Levels

### Novice
- Knows what a mutex is and why race conditions occur
- Uses `pthread_mutex_lock`/`unlock` or `sync.Mutex` correctly
- Understands pipes at the shell level; knows `|` creates an anonymous pipe
- Can describe what a deadlock is and name one scenario where it occurs

### Intermediate
- Implements producer-consumer with condition variables (correct `while` loop)
- Uses POSIX shared memory (`shm_open` + `mmap`) for cross-process data sharing
- Understands POSIX message queues vs shared memory trade-offs
- Writes lock-free SPSC ring buffer with `acquire`/`release` ordering
- Uses Go buffered channels for fan-out; avoids goroutine leaks with context cancellation
- Profiles lock contention with `perf lock` or `pprof mutex`

### Advanced
- Implements false-sharing-free atomics with cache-line padding
- Explains the ABA problem and implements a tagged-pointer solution
- Designs MPSC queues for multi-producer logging pipelines (no allocation in hot path)
- Uses Rust `Arc<Mutex<T>>`, `crossbeam`, and `Rayon` appropriately for each pattern
- Profiles futex contention with `bpftrace` / `perf` to identify hot locks
- Implements epoch-based memory reclamation for lock-free structures in C/C++

### Expert
- Designs wait-free data structures for hard real-time guarantees
- Implements custom memory reclamation (hazard pointers, RCU) for lock-free code
- Analyses the Linux futex implementation (`kernel/futex/`) to optimise IPC
- Evaluates io_uring for async IPC as an alternative to traditional blocking queues
- Architects a zero-copy messaging bus (shared memory + lock-free ring) for HFT or game engines
- Contributes to concurrency library implementations (crossbeam, folly, Java Disruptor)

---

## AI Prompts

```
You are a Linux systems programmer. I need a lock-free multi-producer
single-consumer (MPSC) queue in C using C11 atomics. The queue is used for
logging — multiple threads push log entries, one background thread drains and
writes to disk. Describe the data structure, the correct atomic orderings for
push and pop, and how you would handle the ABA problem if pointers are recycled.
```

```
Acting as a concurrency expert: I have a Go service where 200 goroutines
all acquire the same sync.Mutex to update a shared map. Under load, p99
latency spikes to 50 ms. Walk me through a systematic investigation using
pprof mutex profiles, and propose two alternative designs (sharded mutex
and channels-based serialisation) with the trade-offs of each.
```

```
Explain the C11 memory model acquire/release semantics with a concrete
example of a SPSC queue. Show exactly which atomic store uses
memory_order_release, which load uses memory_order_acquire, and what
would go wrong on an ARM CPU if both used memory_order_relaxed instead.
```

```
Compare three approaches for high-throughput inter-process communication
on Linux between a video decoder process and a rendering process:
(1) POSIX shared memory + semaphore, (2) Unix domain socket with
sendmsg/recvmsg and SCM_RIGHTS, (3) POSIX message queue. For each, give
the latency, throughput, and operational complexity. Assume 1080p frames
at 60 fps.
```

```
I need to design a work-stealing thread pool in Rust for a game engine's
task system. Tasks may spawn sub-tasks. Describe the data structures:
per-thread deque (push/pop from one end by owner, steal from other end
by thieves), how crossbeam-deque implements this, and how to handle
task completion notification without a condition variable (to avoid
latency spikes from OS scheduling).
```

---

## References

- **Love, Robert** — *Linux Kernel Development*, Ch. 5 (System Calls), Ch. 10 (Kernel Synchronisation)
- **Kerrisk, Michael** — *The Linux Programming Interface*, Ch. 44–52 (IPC: pipes, FIFOs, MQ, shm)
- **Preshing, Jeff** — "An Introduction to Lock-Free Programming" (preshing.com)
- **Preshing, Jeff** — "The Happens-Before Relation" and memory ordering series (preshing.com)
- **cppreference.com** — `std::atomic`, memory order, `std::memory_order` — definitive reference
- **crossbeam** — https://github.com/crossbeam-rs/crossbeam — Rust lock-free data structures
- **LMAX Disruptor** — https://lmax-exchange.github.io/disruptor/ — Java high-throughput ring buffer
- **Go Memory Model** — https://go.dev/ref/mem — happens-before guarantees for channels
- **Rust Nomicon** — https://doc.rust-lang.org/nomicon/ — unsafe Rust, atomics, `Send`/`Sync`
- **futex(2)** — `man 2 futex`; Ulrich Drepper "Futexes Are Tricky" (paper)
- **Gregg, Brendan** — *BPF Performance Tools*, Ch. 13 (Applications) — lock profiling with eBPF
- **SysSkills cross-reference** — `os-architecture-foundations`, `memory-management-virtual-memory`,
  `kernel-security`, `process-scheduling`, `filesystems-storage-architecture`
