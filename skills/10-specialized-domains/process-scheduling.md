---
name: Process Scheduling
slug: process-scheduling
category: 10-specialized-domains
proficiency: advanced
description: >
  Master Linux process and thread scheduling: CFS red-black tree and vruntime,
  real-time classes (SCHED_FIFO, SCHED_RR, SCHED_DEADLINE), priority inversion
  and PI-mutex mitigations, cgroup v2 CPU bandwidth control, CPU isolation
  (isolcpus/nohz_full), IRQ affinity, NUMA-aware scheduling, and eBPF-based
  scheduler latency observability. Applicable to cloud workload optimisation,
  HFT, real-time embedded, and multi-tenant Kubernetes.
tags:
  - cfs
  - sched-deadline
  - real-time-scheduling
  - priority-inversion
  - cgroups-v2
  - cpu-isolation
  - numa
  - ebpf
  - linux-kernel
  - performance
status: published
---

## Principles

### 1. CFS Models Fairness Through Virtual Runtime
The Completely Fair Scheduler (kernel default since 2.6.23) assigns each
runnable task a `vruntime` — wall-clock nanoseconds weighted by the task's
`nice` value. The scheduler always runs the task with the lowest `vruntime`,
stored in a per-CPU **red-black tree** (O(log n) pick-next). Nice -20 gets
~10× more CPU time than nice +19. All tuning decisions flow from this model:
raising a task's priority lowers its effective weight, decreasing vruntime
accumulation rate.

### 2. Scheduling Classes Form a Strict Priority Hierarchy
Linux has five scheduling classes in descending priority:
```
stop_sched_class   (stop-machine, highest)
dl_sched_class     (SCHED_DEADLINE — EDF)
rt_sched_class     (SCHED_FIFO / SCHED_RR)
fair_sched_class   (SCHED_NORMAL / SCHED_BATCH — CFS)
idle_sched_class   (SCHED_IDLE — lowest)
```
A deadline task *always* preempts a fair task. A FIFO task *always* preempts
a normal task. Never elevate tasks beyond the class they actually need — each
step up gives hard preemption rights over everything below.

### 3. Real-Time Guarantees Require Isolation, Not Just Priority
`SCHED_FIFO` at priority 99 gives scheduling priority but not latency
*guarantee* if CPUs handle shared interrupts. True determinism requires:
- `isolcpus=` to remove CPUs from the general scheduler
- `nohz_full=` to disable tick interrupts on isolated CPUs
- IRQ affinity configured to non-isolated CPUs
- `rcu_nocbs=` to offload RCU callbacks

Without these, interrupt latency spikes contaminate even FIFO threads.

### 4. Priority Inversion Is a Silent Correctness Bug
Classic scenario: low-priority task L holds mutex M; high-priority task H
blocks on M; medium-priority task M preempts L → H is effectively blocked
behind M indefinitely. Solutions:
- **Priority Inheritance** (`PTHREAD_PRIO_INHERIT`): L temporarily inherits H's priority
- **Priority Ceiling** (`PTHREAD_PRIO_PROTECT`): mutex holders always run at ceiling priority
- **Lock-free data structures**: eliminate the mutex entirely on hot paths

### 5. CPU Bandwidth Without Isolation Creates Noisy Neighbours
cgroup v2 `cpu.max` sets a quota but does not prevent a bursty workload from
consuming all CPU *within* its period before the quota resets. On shared nodes,
`cpu.weight` (CFS weight) is more predictable for steady-state fairness;
`cpu.max` enforces hard ceilings for multi-tenant safety.

---

## Implementation Patterns

### Pattern A: CFS Tuning for Latency vs Throughput
`sched_latency_ns` defines the target scheduling period — the time within
which every runnable task gets at least one time slice. Lower value → lower
latency, higher context-switch overhead:
```bash
# Read current values
cat /proc/sys/kernel/sched_latency_ns        # default: 6000000 (6 ms)
cat /proc/sys/kernel/sched_min_granularity_ns # default: 750000  (0.75 ms)
cat /proc/sys/kernel/sched_wakeup_granularity_ns

# Tune for interactive/low-latency workloads
sysctl -w kernel.sched_latency_ns=2000000        # 2 ms
sysctl -w kernel.sched_min_granularity_ns=500000  # 0.5 ms
sysctl -w kernel.sched_wakeup_granularity_ns=25000

# Tune for throughput (batch/HPC — fewer context switches)
sysctl -w kernel.sched_latency_ns=24000000
sysctl -w kernel.sched_min_granularity_ns=3000000
```

### Pattern B: SCHED_DEADLINE for Sporadic Real-Time Tasks
`SCHED_DEADLINE` implements Earliest Deadline First (EDF). Specify three
parameters: `runtime` (worst-case execution), `deadline` (relative deadline),
`period` (recurrence interval). The kernel performs admission control:
`runtime/period ≤ remaining CPU capacity`.
```c
#include <linux/sched.h>
#include <sys/syscall.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>

struct sched_attr {
    uint32_t size, sched_policy, sched_flags;
    int32_t  sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime, sched_deadline, sched_period;
};

static int sched_setattr(pid_t pid, const struct sched_attr *attr, unsigned int flags) {
    return syscall(314 /* __NR_sched_setattr */, pid, attr, flags);
}

/* Declare: runs 2 ms every 10 ms (20 % CPU budget) */
int set_deadline_task(void) {
    struct sched_attr attr = {
        .size          = sizeof(attr),
        .sched_policy  = 6, /* SCHED_DEADLINE */
        .sched_runtime  = 2 * 1000000ULL,   /* 2 ms  */
        .sched_deadline = 8 * 1000000ULL,   /* 8 ms  */
        .sched_period   = 10 * 1000000ULL,  /* 10 ms */
    };
    if (sched_setattr(0, &attr, 0) < 0) {
        perror("sched_setattr");
        return -1;
    }
    return 0;
}
```

### Pattern C: cgroup v2 CPU Bandwidth + CPU Sets
```bash
# Create a cgroup for an HFT trading process
CGROUP=/sys/fs/cgroup/trading
mkdir -p "$CGROUP"

# Pin to CPUs 4-7 (isolated cores, see Pattern D)
echo "4-7" > "$CGROUP/cpuset.cpus"
echo "0"   > "$CGROUP/cpuset.mems"    # NUMA node 0

# CPU bandwidth: allow 80 ms out of every 100 ms (80 % ceiling)
echo "80000 100000" > "$CGROUP/cpu.max"

# CFS weight: 2× the default (1024) for higher fair-share priority
echo "2048" > "$CGROUP/cpu.weight"

# Assign process
echo $PID > "$CGROUP/cgroup.procs"
```

### Pattern D: CPU Isolation for Hard Real-Time
Add to kernel boot parameters (GRUB `GRUB_CMDLINE_LINUX`):
```bash
# Reserve CPUs 4-7 for real-time workloads
isolcpus=4-7            # exclude from general scheduler
nohz_full=4-7           # disable tick interrupts on isolated CPUs
rcu_nocbs=4-7           # offload RCU callbacks off isolated CPUs

# After boot, migrate all IRQs away from isolated CPUs
for irq in /proc/irq/*/smp_affinity_list; do
    echo "0-3" > "$irq" 2>/dev/null || true
done

# Start the real-time process on an isolated CPU
taskset -c 4 chrt --fifo 90 ./my_rt_process
```

### Pattern E: NUMA-Aware Thread Placement
```c
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

/* Pin thread to a specific NUMA node's CPU set */
int pin_thread_to_numa_node(pthread_t tid, int node, int ncpus_per_node) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    int start = node * ncpus_per_node;
    for (int i = start; i < start + ncpus_per_node; i++)
        CPU_SET(i, &cpuset);
    return pthread_setaffinity_np(tid, sizeof(cpuset), &cpuset);
}

/* Worker thread that self-pins on startup */
void* numa_worker(void *arg) {
    int node = (int)(intptr_t)arg;
    if (pin_thread_to_numa_node(pthread_self(), node, 8) != 0)
        perror("setaffinity");

    /* Memory allocation should follow thread placement */
    /* Use numa_alloc_onnode() from libnuma if available */
    while (1) {
        /* ... process workload local to node ... */
    }
    return NULL;
}

int main(void) {
    pthread_t t[2];
    for (int i = 0; i < 2; i++)
        pthread_create(&t[i], NULL, numa_worker, (void*)(intptr_t)i);
    for (int i = 0; i < 2; i++)
        pthread_join(t[i], NULL);
}
```

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| `SCHED_FIFO` priority 99 on all threads | Any spinning thread starves the entire system; kernel watchdog may not recover | Use `SCHED_DEADLINE` for bounded tasks; FIFO only for true hard-RT |
| `sched_rt_runtime_us = -1` (disable RT throttling) | RT tasks can lock up the machine indefinitely | Keep default 950000 µs / 1000000 µs; use `isolcpus` for guarantees instead |
| Ignoring priority inversion | High-priority thread blocks behind low-priority indefinitely | Use `PTHREAD_PRIO_INHERIT` mutexes; avoid mutexes on RT paths entirely |
| `cpu.max` quota without `cpuset.cpus` | Burst workloads still share CPU with RT tasks during quota window | Combine bandwidth control with CPU isolation |
| Tuning `sched_latency_ns` system-wide | Aggressive tuning hurts throughput workloads running on same node | Use cgroup CPU sets to partition RT and batch workloads onto different CPUs |
| Spawning goroutines without `GOMAXPROCS` tuning | Go runtime may schedule across all CPUs including RT-isolated ones | Set `GOMAXPROCS` to exclude isolated CPUs; pin hot goroutines with `LockOSThread` |
| No latency measurement (`cyclictest`) before claiming RT | "It works in testing" ≠ deterministic; jitter sources are non-obvious | Run `cyclictest` under load for ≥ 1 hour; target p99.9 < deadline |
| Kubernetes `requests == limits` on latency-sensitive pods | CFS quota enforcement adds 1–5 ms scheduling jitter | Set `requests` only (no `limits`) for latency-sensitive pods; use Guaranteed QoS sparingly |

---

## Code Templates

### Template 1 — C: Priority Inheritance Mutex (Real-Time Safe)
```c
#include <pthread.h>
#include <stdio.h>

pthread_mutex_t pi_mutex;

void init_pi_mutex(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);

    /* Priority Inheritance: lock holder temporarily inherits highest
       waiter's priority — prevents priority inversion */
    pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);

    /* PTHREAD_PRIO_PROTECT alternative: holder always runs at ceiling.
       Use when ceiling is known; lower overhead than PI on hot paths. */
    /* pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_PROTECT);   */
    /* pthread_mutexattr_setprioceiling(&attr, 90);                  */

    pthread_mutex_init(&pi_mutex, &attr);
    pthread_mutexattr_destroy(&attr);
}

void* high_priority_worker(void *arg) {
    struct sched_param sp = { .sched_priority = 80 };
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);

    pthread_mutex_lock(&pi_mutex);
    /* Critical section — if a lower-priority thread holds the lock,
       it is boosted to priority 80 until it releases */
    do_critical_work();
    pthread_mutex_unlock(&pi_mutex);
    return NULL;
}
```

### Template 2 — Go: Scheduler Tuning for Latency-Critical Service
```go
package main

import (
    "fmt"
    "runtime"
    "runtime/debug"
    "time"
    "os"
    "strconv"
)

func init() {
    // Leave one CPU for GC mark goroutines and system tasks.
    // On an isolated 4-core partition, this means 3 goroutines can run
    // concurrently without competing with the GC mark phase.
    n := runtime.NumCPU()
    if n > 1 {
        runtime.GOMAXPROCS(n - 1)
    }

    // Reduce GC frequency; combined with GOMEMLIMIT this avoids
    // mid-request GC pauses on latency-sensitive paths.
    debug.SetGCPercent(400)
    debug.SetMemoryLimit(512 << 20) // 512 MiB

    if v := os.Getenv("GOMAXPROCS"); v != "" {
        if n, err := strconv.Atoi(v); err == nil {
            runtime.GOMAXPROCS(n)
        }
    }
}

// LockToCore pins the calling goroutine's OS thread to the current CPU.
// Use for goroutines that drive hardware or hold RT-class file descriptors.
func LockToCore(work func()) {
    done := make(chan struct{})
    go func() {
        runtime.LockOSThread()    // goroutine and OS thread are now 1:1
        defer runtime.UnlockOSThread()
        defer close(done)
        work()
    }()
    <-done
}

// SchedulerLatency measures the time between a goroutine waking and
// actually running — a proxy for Go runtime scheduler latency.
func SchedulerLatency() time.Duration {
    ch := make(chan time.Time, 1)
    sent := time.Now()
    go func() { ch <- time.Now() }()
    received := <-ch
    return received.Sub(sent)
}

func main() {
    for i := 0; i < 5; i++ {
        fmt.Printf("scheduler latency: %v\n", SchedulerLatency())
    }
}
```

### Template 3 — Python BCC: Scheduler Run-Queue Latency Histogram
```python
#!/usr/bin/env python3
"""runq_latency.py — histogram of time tasks wait in run queue before
   getting a CPU (scheduler latency). Uses sched_switch tracepoint."""
from bcc import BPF
import sys, time, signal

PROG = r"""
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

BPF_HASH(enqueue_ts, u32, u64);          // pid -> enqueue timestamp
BPF_HISTOGRAM(runq_lat, u64, 64);        // nanoseconds histogram

// Fired when a task becomes runnable (enters run queue)
TRACEPOINT_PROBE(sched, sched_wakeup) {
    u32 pid = args->pid;
    u64 ts  = bpf_ktime_get_ns();
    enqueue_ts.update(&pid, &ts);
    return 0;
}

TRACEPOINT_PROBE(sched, sched_wakeup_new) {
    u32 pid = args->pid;
    u64 ts  = bpf_ktime_get_ns();
    enqueue_ts.update(&pid, &ts);
    return 0;
}

// Fired when the task is actually scheduled onto a CPU
TRACEPOINT_PROBE(sched, sched_switch) {
    u32 next_pid = args->next_pid;
    u64 *tsp = enqueue_ts.lookup(&next_pid);
    if (!tsp) return 0;

    u64 lat = bpf_ktime_get_ns() - *tsp;
    enqueue_ts.delete(&next_pid);

    // Filter: only record latency for target PID (0 = all)
    u32 filter_pid = FILTER_PID;
    if (filter_pid != 0 && next_pid != filter_pid) return 0;

    runq_lat.increment(bpf_log2l(lat));
    return 0;
}
"""

target_pid = int(sys.argv[1]) if len(sys.argv) > 1 else 0
prog = PROG.replace("FILTER_PID", str(target_pid))

b = BPF(text=prog)
print(f"Tracing scheduler run-queue latency"
      f"{' for PID '+str(target_pid) if target_pid else ' (all PIDs)'}."
      f" Ctrl-C to print histogram.")

def print_and_exit(sig, frame):
    print()
    b["runq_lat"].print_log2_hist("latency (ns)")
    sys.exit(0)

signal.signal(signal.SIGINT, print_and_exit)
while True:
    time.sleep(1)
```

### Template 4 — Shell: cyclictest Real-Time Latency Benchmark
```bash
#!/usr/bin/env bash
# rt_latency_test.sh — measure scheduling latency on isolated CPUs.
# Requires: rt-tests (cyclictest), stress-ng for background load.

ISOLATED_CPUS="4-7"
RT_PRIO=90
DURATION=60   # seconds

echo "[1] Checking kernel preemption model..."
grep -E 'PREEMPT|PREEMPT_RT' /boot/config-$(uname -r) | grep -v "^#" || \
    echo "WARNING: PREEMPT_RT not enabled — latency results may be high"

echo "[2] Disable CPU frequency scaling on isolated cores..."
for cpu in $(seq 4 7); do
    echo performance > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor
done

echo "[3] Start background CPU stress on non-isolated cores..."
taskset -c 0-3 stress-ng --cpu 4 --timeout ${DURATION}s &
STRESS_PID=$!

echo "[4] Running cyclictest for ${DURATION}s on CPUs ${ISOLATED_CPUS}..."
taskset -c "${ISOLATED_CPUS}" cyclictest \
    --mlockall \
    --smp \
    --priority=${RT_PRIO} \
    --interval=200 \
    --distance=0 \
    --duration=${DURATION} \
    --histogram=400 \
    --histfile=/tmp/cyclictest_hist.txt \
    --quiet

wait $STRESS_PID

echo "[5] Results (min/avg/max latency in µs):"
grep -E "^T:" /tmp/cyclictest_hist.txt | head -8

echo "[6] Histogram saved to /tmp/cyclictest_hist.txt"
echo "     Plot with: gnuplot -p -e 'plot \"/tmp/cyclictest_hist.txt\" using 1:2 with lines'"
```

### Template 5 — C: CPU Affinity + Real-Time Thread Bootstrap
```c
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

typedef struct {
    int cpu;
    int priority;
    void (*work)(void);
} rt_thread_cfg_t;

static void* rt_thread_entry(void *arg) {
    rt_thread_cfg_t *cfg = arg;

    /* Pin to specific CPU */
    cpu_set_t mask;
    CPU_ZERO(&mask);
    CPU_SET(cfg->cpu, &mask);
    if (pthread_setaffinity_np(pthread_self(), sizeof(mask), &mask) != 0)
        perror("setaffinity");

    /* Elevate scheduling class */
    struct sched_param sp = { .sched_priority = cfg->priority };
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) != 0)
        perror("setschedparam — needs CAP_SYS_NICE or root");

    /* Lock memory — prevent page faults during RT execution */
    mlockall(MCL_CURRENT | MCL_FUTURE);

    cfg->work();
    return NULL;
}

pthread_t spawn_rt_thread(int cpu, int priority, void (*work)(void)) {
    rt_thread_cfg_t *cfg = malloc(sizeof(*cfg));
    cfg->cpu      = cpu;
    cfg->priority = priority;
    cfg->work     = work;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    /* Pre-allocate 1 MiB stack — avoid fault on first stack page use */
    pthread_attr_setstacksize(&attr, 1 << 20);

    pthread_t tid;
    pthread_create(&tid, &attr, rt_thread_entry, cfg);
    pthread_attr_destroy(&attr);
    return tid;
}
```

### Template 6 — eBPF: Per-Process Context Switch Rate Monitor (libbpf)
```c
/* ctx_switch_rate.bpf.c — count context switches per PID */
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct cs_key { u32 pid; };
struct cs_val { u64 voluntary; u64 involuntary; };

BPF_HASH(cs_counts, struct cs_key, struct cs_val);

/* sched_switch fires on every context switch */
SEC("tp/sched/sched_switch")
int count_ctx_switch(struct trace_event_raw_sched_switch *ctx) {
    /* prev_state: 0 = TASK_RUNNING (involuntary), else voluntary */
    bool voluntary = ctx->prev_state != 0;

    struct cs_key key = { .pid = ctx->prev_pid };
    struct cs_val *v = bpf_map_lookup_or_try_init(&cs_counts, &key,
                           &(struct cs_val){});
    if (!v) return 0;

    if (voluntary) __sync_fetch_and_add(&v->voluntary, 1);
    else           __sync_fetch_and_add(&v->involuntary, 1);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```
```python
# Userspace loader (Python/ctypes — simplified)
# Full implementation: compile BPF, open map, poll and print top-N PIDs
# by involuntary context switches (high involuntary rate → CPU contention)
import subprocess, time
# Use bpftool map dump cs_counts or BCC's BPF map Python API
```

---

## Decision Matrix

| Workload Type | Scheduler Class | Key Settings | Notes |
|---|---|---|---|
| General-purpose HTTP server | `SCHED_NORMAL` (CFS) | `sched_latency_ns=4ms`, nice=0 | Default; no tuning needed unless latency SLO < 10 ms |
| Interactive desktop / low-latency audio | CFS + nice -10 | `sched_latency_ns=2ms`; `sched_wakeup_granularity=25µs` | PipeWire/JACK use SCHED_FIFO; tune CFS for non-RT threads |
| Periodic RT task (motor control, 1 kHz) | `SCHED_DEADLINE` | `runtime=0.5ms`, `deadline=0.9ms`, `period=1ms` | Kernel admission control enforces budget; preferred over FIFO |
| Bounded high-priority daemon | `SCHED_FIFO` | priority 50–80; `isolcpus`; `mlockall` | Must be bounded; use watchdog to detect spin |
| Batch / offline ML training | `SCHED_BATCH` or `SCHED_IDLE` | nice +10 to +19 | Voluntary yielding; won't interfere with interactive tasks |
| Multi-tenant Kubernetes node | CFS + cgroup v2 | `cpu.max`, `cpu.weight`; no `isolcpus` | `cpu.max` for hard ceiling; `cpu.weight` for fair sharing |
| HFT / trading engine | `SCHED_FIFO` + `isolcpus` + `nohz_full` | PREEMPT_RT kernel; `cyclictest` p99.9 < 30 µs | Full RT stack: BIOS C-states off, hyperthreading off |
| Kubernetes latency-sensitive pod | `SCHED_NORMAL`, no `limits` | `requests` only (Burstable QoS) | `limits.cpu` → `cpu.max` → CFS quota jitter |

---

## Proficiency Levels

### Novice
- Distinguishes processes vs threads; understands preemptive scheduling
- Reads `top` output: `%us`, `%sy`, `%wa`, load average
- Knows `nice` and `renice`; applies them to reduce batch job priority
- Understands that CFS is the Linux default and context switches have cost

### Intermediate
- Explains vruntime, CFS red-black tree, and how `nice` maps to CPU share
- Configures `sched_latency_ns` and `sched_min_granularity_ns` for target workloads
- Sets up cgroup v2 `cpu.max` and `cpu.weight`; pins workloads with `taskset`
- Diagnoses priority inversion; applies `PTHREAD_PRIO_INHERIT` mutexes
- Uses `perf sched latency` and `sched_switch` tracepoints to measure scheduling

### Advanced
- Configures `SCHED_FIFO`/`SCHED_DEADLINE` with correct parameters and admission control
- Sets up full RT isolation: `isolcpus`, `nohz_full`, `rcu_nocbs`, IRQ affinity
- Writes eBPF programs tracing `sched_switch`, `sched_wakeup` for latency histograms
- Interprets `cyclictest` results; identifies jitter sources (SMI, C-states, hyperthreading)
- Tunes NUMA-aware thread placement with `pthread_setaffinity_np` + `mbind`
- Configures Kubernetes QoS classes and understands their cgroup mappings

### Expert
- Designs multi-tier scheduling architecture for mixed RT + batch + interactive workloads
- Patches or extends CFS (implements custom scheduling policy via `sched_ext` BPF in kernel 6.11+)
- Architects RT systems on `PREEMPT_RT`-patched kernels; validates with formal timing analysis
- Evaluates `sched_ext` (BPF-extensible scheduler) for workload-specific scheduling algorithms
- Performs scheduler profiling at the kernel level: `perf record -e sched:*`, flame graphs of wakeup latency

---

## AI Prompts

```
You are a Linux real-time systems engineer. I need to run a 1 kHz control loop
on a 16-core server with cores 8-15 reserved for real-time tasks. Walk me
through the complete setup: kernel boot parameters, IRQ migration, cgroup
isolation, SCHED_DEADLINE parameters for a 0.5 ms runtime / 1 ms period task,
and how to validate latency with cyclictest. Include the exact commands.
```

```
Acting as a performance engineer: a Kubernetes node running mixed latency-
sensitive and batch workloads has p99 latency spikes of 50 ms every 30 seconds.
The node has 32 cores and no CPU isolation. Describe a step-by-step diagnosis
plan: which BPF/perf tools to run, what to look for in cgroup cpu.stat, and
what scheduling or cgroup changes to try first.
```

```
Explain the priority inversion problem with a concrete C example using three
POSIX threads at different SCHED_FIFO priorities sharing a mutex. Then show
the fix using PTHREAD_PRIO_INHERIT and explain why PTHREAD_PRIO_PROTECT is
sometimes preferable in hard real-time contexts.
```

```
Compare SCHED_FIFO, SCHED_RR, and SCHED_DEADLINE for a periodic sensor
data aggregation task that must complete within 3 ms every 10 ms. Which class
provides the strongest guarantee, why, and what happens if the task overruns
its budget under each class?
```

```
The new Linux sched_ext framework (kernel 6.11+) allows writing custom
scheduling policies in BPF. Describe a scheduling policy you would design
for a database server running mixed OLTP and OLAP queries. What scheduling
decisions would your BPF scheduler make, and what kernel data would it read
to make them?
```

---

## References

- **Arpaci-Dusseau, R. & A.** — *Operating Systems: Three Easy Pieces*, Ch. 7–10 (Scheduling)
- **Love, Robert** — *Linux Kernel Development*, Ch. 4 (Process Scheduling)
- **Linux CFS design document** — `Documentation/scheduler/sched-design-CFS.rst`
- **SCHED_DEADLINE** — `Documentation/scheduler/sched-deadline.rst`; RFC 5905
- **RT-Linux (PREEMPT_RT)** — https://wiki.linuxfoundation.org/realtime/start
- **rt-tests / cyclictest** — https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git
- **sched_ext (BPF scheduler)** — `Documentation/scheduler/sched-ext.rst` (kernel ≥ 6.11)
- **Gregg, Brendan** — *BPF Performance Tools*, Ch. 14 (Scheduler)
- **perf-sched** — `man 1 perf-sched`; `perf sched latency`, `perf sched timehist`
- **POSIX PI mutexes** — `man 3 pthread_mutexattr_setprotocol`
- **Linux cgroup v2 CPU** — `Documentation/admin-guide/cgroup-v2.rst` §CPU
- **Kubernetes CPU management** — https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- **tglx/linux** — Thomas Gleixner's RT patchset history and design rationale
