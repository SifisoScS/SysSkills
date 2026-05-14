---
name: Kernel Security
slug: kernel-security
category: 10-specialized-domains
proficiency: advanced
description: >
  Master the Linux kernel security model: capabilities, seccomp-bpf syscall
  filtering, Landlock LSM filesystem sandboxing, SELinux/AppArmor mandatory
  access control, eBPF-based runtime enforcement, and kernel hardening
  (KASLR, KPTI, CFI, shadow stacks). Covers container security contexts,
  Kubernetes PodSecurity, and confidential computing (AMD SEV-SNP, Intel TDX).
tags:
  - capabilities
  - seccomp-bpf
  - landlock
  - selinux
  - apparmor
  - lsm
  - ebpf
  - kernel-hardening
  - confidential-computing
  - container-security
status: published
---

## Principles

### 1. Least Privilege Is a Kernel Contract, Not a Policy Suggestion
The Linux privilege model was historically binary: root (UID 0) vs. everyone
else. Capabilities split root into ~41 discrete privileges. Every service,
container, and kernel thread must hold exactly the set it needs and nothing more.
Audit with `capsh --print`; enforce with `setcap`/`prctl(PR_CAP_AMBIENT_*)`.

### 2. Defense in Depth — Layer Independent Controls
No single mechanism is sufficient. Layer controls so that bypassing one leaves
others intact:
```
Hardware (SMEP/SMAP/CET) → Kernel compile-time hardening (CFI/KCFI/SCS)
    → Kernel runtime mitigations (KASLR/KPTI) → LSM (SELinux/AppArmor/Landlock)
        → seccomp-bpf → Capabilities drop → Namespaces
```
Each layer must be independently enforceable and independently auditable.

### 3. The Syscall Interface Is the Attack Surface
The kernel exposes ~350 syscalls. Every syscall reachable from an untrusted
process is a potential exploitation vector (e.g., `ptrace`, `perf_event_open`,
`userfaultfd`). seccomp-bpf reduces the reachable syscall set to only what the
process legitimately needs.

### 4. Mandatory Access Control Removes Root's Discretion
DAC (Discretionary Access Control) lets root override any permission decision.
MAC (SELinux type enforcement, AppArmor profiles, Landlock rules) enforces
access policy *regardless* of process privilege. A compromised root process
confined by SELinux cannot read `/etc/shadow` if the policy forbids it.

### 5. Kernel Integrity Must Be Continuously Verified
Boot-time verification (Secure Boot + dm-verity) prevents offline tampering.
Runtime integrity (IMA/EVM, kernel module signing, KCFI) prevents live
injection. Confidential Computing (SEV-SNP, TDX) extends the trust boundary
to the hypervisor layer, enabling remote attestation of kernel and workload.

---

## Implementation Patterns

### Pattern A: Capabilities Bounding Set Minimisation
Drop all capabilities not required at exec time; clear the ambient set for
non-privileged child processes:
```c
// After fork, before exec — drop capabilities to minimum viable set
#include <sys/capability.h>
#include <sys/prctl.h>

void drop_capabilities(void) {
    // Clear bounding set — inherited caps cannot exceed this
    for (int cap = 0; cap <= CAP_LAST_CAP; cap++) {
        if (cap == CAP_NET_BIND_SERVICE) continue; // keep if binding <1024
        prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
    }
    // Clear ambient set
    prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);

    cap_t caps = cap_get_proc();
    cap_clear(caps);
    if (/* needs port 80 */ true) {
        cap_value_t keep[] = { CAP_NET_BIND_SERVICE };
        cap_set_flag(caps, CAP_PERMITTED,   1, keep, CAP_SET);
        cap_set_flag(caps, CAP_EFFECTIVE,   1, keep, CAP_SET);
    }
    cap_set_proc(caps);
    cap_free(caps);

    // Lock: prevent future privilege escalation via execve
    prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}
```

### Pattern B: Seccomp-BPF Allowlist Profile
Allowlist only the syscalls required; every other syscall returns `ENOSYS`
(or kills the process for critical violations):
```c
#include <seccomp.h>   /* libseccomp */

int install_seccomp_filter(void) {
    scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ERRNO(ENOSYS));
    if (!ctx) return -1;

    /* Minimal HTTP server syscall set */
    const int allowed[] = {
        SCMP_SYS(read), SCMP_SYS(write), SCMP_SYS(close),
        SCMP_SYS(accept4), SCMP_SYS(recv), SCMP_SYS(send),
        SCMP_SYS(epoll_wait), SCMP_SYS(epoll_ctl),
        SCMP_SYS(mmap), SCMP_SYS(munmap), SCMP_SYS(brk),
        SCMP_SYS(exit_group), SCMP_SYS(futex),
        SCMP_SYS(clock_gettime), SCMP_SYS(gettimeofday),
    };
    for (size_t i = 0; i < sizeof(allowed)/sizeof(*allowed); i++)
        seccomp_rule_add(ctx, SCMP_ACT_ALLOW, allowed[i], 0);

    /* Kill on exec attempts — process should never exec after startup */
    seccomp_rule_add(ctx, SCMP_ACT_KILL_PROCESS, SCMP_SYS(execve), 0);
    seccomp_rule_add(ctx, SCMP_ACT_KILL_PROCESS, SCMP_SYS(execveat), 0);

    int rc = seccomp_load(ctx);
    seccomp_release(ctx);
    return rc;
}
```

### Pattern C: Landlock Filesystem Sandbox (Kernel 5.13+)
Landlock is an unprivileged LSM — no `CAP_SYS_ADMIN` needed. Any process can
restrict its own filesystem view:
```c
#include <linux/landlock.h>
#include <sys/syscall.h>
#include <fcntl.h>

#define LL_ACCESS_FS_READ  (LANDLOCK_ACCESS_FS_READ_FILE  | \
                            LANDLOCK_ACCESS_FS_READ_DIR)
#define LL_ACCESS_FS_WRITE (LANDLOCK_ACCESS_FS_WRITE_FILE | \
                            LANDLOCK_ACCESS_FS_REMOVE_FILE| \
                            LANDLOCK_ACCESS_FS_MAKE_REG)

static inline int landlock_create_ruleset(
        const struct landlock_ruleset_attr *attr, size_t size, uint32_t flags) {
    return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
static inline int landlock_add_rule(int fd, enum landlock_rule_type type,
        const void *attr, uint32_t flags) {
    return syscall(__NR_landlock_add_rule, fd, type, attr, flags);
}
static inline int landlock_restrict_self(int fd, uint32_t flags) {
    return syscall(__NR_landlock_restrict_self, fd, flags);
}

int sandbox_filesystem(void) {
    struct landlock_ruleset_attr rs_attr = {
        .handled_access_fs = LL_ACCESS_FS_READ | LL_ACCESS_FS_WRITE,
    };
    int rs_fd = landlock_create_ruleset(&rs_attr, sizeof(rs_attr), 0);
    if (rs_fd < 0) return -1;

    /* Allow read-only access to /etc */
    struct landlock_path_beneath_attr ro = {
        .allowed_access = LL_ACCESS_FS_READ,
        .parent_fd = open("/etc", O_PATH | O_CLOEXEC),
    };
    landlock_add_rule(rs_fd, LANDLOCK_RULE_PATH_BENEATH, &ro, 0);
    close(ro.parent_fd);

    /* Allow read-write to /var/app/data */
    struct landlock_path_beneath_attr rw = {
        .allowed_access = LL_ACCESS_FS_READ | LL_ACCESS_FS_WRITE,
        .parent_fd = open("/var/app/data", O_PATH | O_CLOEXEC),
    };
    landlock_add_rule(rs_fd, LANDLOCK_RULE_PATH_BENEATH, &rw, 0);
    close(rw.parent_fd);

    prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    int rc = landlock_restrict_self(rs_fd, 0);
    close(rs_fd);
    return rc;
}
```

### Pattern D: eBPF Runtime Security Audit (Falco-style)
Detect privilege escalation in real time with a BPF program attached to
`commit_creds` and `security_bprm_check`:
```c
/* kernel_audit.bpf.c — requires libbpf + BTF-enabled kernel */
#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct event {
    __u32 pid;
    __u32 uid;
    __u32 new_uid;
    char  comm[16];
};

struct { __uint(type, BPF_MAP_TYPE_RINGBUF); __uint(max_entries, 1<<20); } events SEC(".maps");

SEC("kprobe/commit_creds")
int BPF_KPROBE(trace_commit_creds, struct cred *new) {
    __u32 old_uid = bpf_get_current_uid_gid() & 0xffffffff;
    __u32 new_uid = BPF_CORE_READ(new, uid.val);

    if (new_uid == 0 && old_uid != 0) {   /* UID 0 escalation */
        struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (!e) return 0;
        e->pid     = bpf_get_current_pid_tgid() >> 32;
        e->uid     = old_uid;
        e->new_uid = new_uid;
        bpf_get_current_comm(e->comm, sizeof(e->comm));
        bpf_ringbuf_submit(e, 0);
    }
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

### Pattern E: Kubernetes PodSecurity Hardening
```yaml
# Kubernetes PodSecurityContext — production baseline
apiVersion: v1
kind: Pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534           # nobody
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault      # applies CRI-default seccomp profile
    sysctls: []                 # no unsafe kernel param overrides

  containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
        add: []                 # add specific caps only if required
      privileged: false
    volumeMounts:
    - name: tmp
      mountPath: /tmp           # writable scratch under tmpfs

  volumes:
  - name: tmp
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| `privileged: true` in Kubernetes pods | Full host kernel access; complete container escape | Drop all caps; use `securityContext.capabilities.drop: [ALL]` |
| `--security-opt seccomp=unconfined` in Docker | All ~350 syscalls reachable; exploitable kernel attack surface | Use `RuntimeDefault` or a custom allowlist profile |
| Disabling SELinux/AppArmor "temporarily" | Mandatory access control silently gone; never re-enabled | Fix the policy violation instead; use `audit2allow` to diagnose |
| `CAP_SYS_ADMIN` granted broadly | Equivalent to root for practical purposes | Decompose into specific caps: `CAP_NET_ADMIN`, `CAP_SYS_CHROOT`, etc. |
| Ignoring `NO_NEW_PRIVS` flag | `setuid` binaries and file capabilities escalate privileges post-exec | Call `prctl(PR_SET_NO_NEW_PRIVS, 1)` before exec |
| Mounting `/proc` or `/sys` into containers | Exposes host kernel state; enables container breakout via `sysfs` writes | Use `maskedPaths` + `readOnlyPaths` in OCI runtime spec |
| seccomp SCMP_ACT_LOG in production | Silent policy bypass; log-only profiles provide no enforcement | Use `SCMP_ACT_ERRNO` or `SCMP_ACT_KILL_PROCESS` in production |
| Not pinning kernel versions in CI | Kernel update changes seccomp/LSM behaviour; breaks production | Pin kernel in CI; test profile changes in staging before rollout |

---

## Code Templates

### Template 1 — Shell: Minimal Capability Drop for Systemd Unit
```ini
# /etc/systemd/system/myapp.service
[Service]
User=myapp
Group=myapp
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Seccomp — use systemd's built-in filter
SystemCallFilter=@system-service
SystemCallFilter=~@debug @mount @reboot @swap @privileged

# Filesystem restrictions (Landlock-equivalent via systemd)
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/myapp

# Namespace isolation
PrivateNetwork=false
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
```

### Template 2 — Go: Runtime Privilege Verification
```go
package security

import (
    "fmt"
    "os"
    "syscall"
    "unsafe"
)

const (
    CAP_NET_BIND_SERVICE = 10
    CAP_SYS_PTRACE       = 19
)

type capHeader struct {
    version uint32
    pid     int32
}
type capData struct {
    effective   uint32
    permitted   uint32
    inheritable uint32
}

func GetEffectiveCapabilities() (uint64, error) {
    hdr := capHeader{version: 0x20080522 /* _LINUX_CAPABILITY_VERSION_3 */}
    var data [2]capData
    _, _, errno := syscall.Syscall(syscall.SYS_CAPGET,
        uintptr(unsafe.Pointer(&hdr)),
        uintptr(unsafe.Pointer(&data[0])), 0)
    if errno != 0 {
        return 0, errno
    }
    return uint64(data[0].effective) | (uint64(data[1].effective) << 32), nil
}

func HasCapability(cap int) (bool, error) {
    eff, err := GetEffectiveCapabilities()
    if err != nil {
        return false, err
    }
    return eff&(1<<uint(cap)) != 0, nil
}

// AssertNotRoot exits the process if running as UID 0 without explicit intent.
func AssertNotRoot() {
    if os.Getuid() == 0 {
        fmt.Fprintln(os.Stderr, "FATAL: service must not run as root")
        os.Exit(1)
    }
}

// AssertSeccompActive panics if seccomp is not enforcing.
// Reads /proc/self/status field "Seccomp:".
func AssertSeccompActive() error {
    data, err := os.ReadFile("/proc/self/status")
    if err != nil {
        return err
    }
    for _, line := range splitLines(string(data)) {
        if len(line) > 8 && line[:8] == "Seccomp:" {
            val := line[9:]
            // 0=disabled, 1=strict, 2=filter
            if val == "0\n" || val == "0" {
                return fmt.Errorf("seccomp not active (mode=0)")
            }
            return nil
        }
    }
    return fmt.Errorf("could not determine seccomp status")
}

func splitLines(s string) []string {
    var lines []string
    start := 0
    for i, c := range s {
        if c == '\n' {
            lines = append(lines, s[start:i+1])
            start = i + 1
        }
    }
    return lines
}
```

### Template 3 — Python BCC: Setuid/Privilege Escalation Monitor
```python
#!/usr/bin/env python3
"""priv_escalation.py — detect UID 0 escalations in real time."""
from bcc import BPF
import ctypes, os, pwd, time

PROG = r"""
#include <linux/sched.h>
#include <linux/cred.h>

struct event_t {
    u32 pid;
    u32 old_uid;
    u32 new_uid;
    char comm[TASK_COMM_LEN];
    char filename[64];
};

BPF_PERF_OUTPUT(events);

int trace_commit_creds(struct pt_regs *ctx, struct cred *new_cred) {
    u32 old_uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    u32 new_uid = new_cred->uid.val;

    if (!(new_uid == 0 && old_uid != 0))
        return 0;

    struct event_t e = {};
    e.pid     = bpf_get_current_pid_tgid() >> 32;
    e.old_uid = old_uid;
    e.new_uid = new_uid;
    bpf_get_current_comm(e.comm, sizeof(e.comm));
    events.perf_submit(ctx, &e, sizeof(e));
    return 0;
}
"""

class Event(ctypes.Structure):
    _fields_ = [
        ("pid",     ctypes.c_uint),
        ("old_uid", ctypes.c_uint),
        ("new_uid", ctypes.c_uint),
        ("comm",    ctypes.c_char * 16),
        ("filename",ctypes.c_char * 64),
    ]

b = BPF(text=PROG)
b.attach_kprobe(event="commit_creds", fn_name="trace_commit_creds")

def handle_event(cpu, data, size):
    e = ctypes.cast(data, ctypes.POINTER(Event)).contents
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] ALERT: UID escalation  pid={e.pid}  "
          f"uid {e.old_uid}→{e.new_uid}  comm={e.comm.decode()}")

b["events"].open_perf_buffer(handle_event)
print("Monitoring for UID 0 escalations... Ctrl-C to stop")
while True:
    b.perf_buffer_poll()
```

### Template 4 — SELinux Policy Module (Targeted Policy)
```
# myapp.te — SELinux type enforcement policy for myapp
# Compile: checkmodule -M -m -o myapp.mod myapp.te
#          semodule_package -o myapp.pp -m myapp.mod
#          semodule -i myapp.pp

module myapp 1.0;

require {
    type httpd_t;
    type myapp_t;
    type myapp_exec_t;
    type myapp_data_t;
    type myapp_log_t;
    class file   { read write execute open getattr create unlink };
    class dir    { read search add_name remove_name };
    class tcp_socket { listen accept connect };
    class process { setrlimit };
}

# Type transitions
type_transition httpd_t myapp_exec_t : process myapp_t;

# Allow myapp to bind/listen on port 8080
allow myapp_t myapp_t : tcp_socket { listen accept };

# Allow read-only access to app config
allow myapp_t myapp_data_t : file { read open getattr };
allow myapp_t myapp_data_t : dir  { read search };

# Allow write access to logs only
allow myapp_t myapp_log_t : file { write open getattr create };
allow myapp_t myapp_log_t : dir  { read search add_name };

# Deny everything else by default (type enforcement is deny-by-default)
```

### Template 5 — Kernel Hardening: sysctl + Boot Parameters Reference
```bash
#!/usr/bin/env bash
# kernel-hardening.sh — apply runtime kernel hardening via sysctl
# Source: CIS Benchmark Level 2, KSPP recommendations

# Kernel pointer hiding (prevents leaking kernel ASLR via /proc)
sysctl -w kernel.kptr_restrict=2
sysctl -w kernel.dmesg_restrict=1

# Disable kernel module auto-loading (reduce attack surface)
sysctl -w kernel.modules_disabled=1     # set AFTER all modules loaded

# Restrict ptrace to parent process only
sysctl -w kernel.yama.ptrace_scope=1

# BPF JIT hardening (mitigates JIT spray attacks)
sysctl -w net.core.bpf_jit_harden=2

# Prevent userfaultfd cross-process use (exploited in many UAF chains)
sysctl -w vm.unprivileged_userfaultfd=0

# Restrict perf_event_open (high-privilege side-channel vector)
sysctl -w kernel.perf_event_paranoid=3

# Network hardening
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.conf.all.accept_redirects=0
sysctl -w net.ipv4.tcp_syncookies=1

# --- GRUB boot parameters (append to GRUB_CMDLINE_LINUX in /etc/default/grub) ---
# kaslr                   — kernel ASLR (usually on by default)
# pti=on                  — Kernel Page Table Isolation (Meltdown mitigation)
# spectre_v2=on           — Spectre v2 mitigation
# l1tf=full,force         — L1TF mitigation
# mds=full,nosmt          — MDS mitigation
# tsx=off                 — Disable TSX (TAA attack surface)
# init_on_alloc=1         — Zero-fill pages on alloc (prevents info leaks)
# init_on_free=1          — Zero-fill pages on free  (prevents use-after-free reads)
# slab_nomerge            — Prevent slab merging (blocks heap layout manipulation)
# page_alloc.shuffle=1    — ASLR for page allocator
# vsyscall=none           — Disable legacy vsyscall (ROP gadget source)
# debugfs=off             — Disable debugfs (attack surface)
```

### Template 6 — Confidential Computing: Intel TDX Attestation Sketch (Go)
```go
// tdx_attest.go — request and verify a TDX quote (requires tdx-guest kernel module)
package tdx

import (
    "crypto/sha512"
    "encoding/hex"
    "fmt"
    "os"
    "unsafe"
    "syscall"
)

// IOCTL constants for /dev/tdx_guest (Linux 6.2+)
const (
    TDX_CMD_GET_REPORT0 = 0xc0a00a01 // _IOWR(0xa0, 0x01, tdx_report_req)
    REPORT_DATA_SIZE    = 64
    TDX_REPORT_SIZE     = 1024
)

type TdxReportReq struct {
    ReportData [REPORT_DATA_SIZE]byte
    TdReport   [TDX_REPORT_SIZE]byte
}

// GetTDReport returns a TD Report bound to the provided nonce.
// The nonce should be a server-provided random value to prevent replay.
func GetTDReport(nonce []byte) ([]byte, error) {
    fd, err := os.Open("/dev/tdx_guest")
    if err != nil {
        return nil, fmt.Errorf("TDX not available: %w", err)
    }
    defer fd.Close()

    var req TdxReportReq
    h := sha512.New()
    h.Write(nonce)
    copy(req.ReportData[:], h.Sum(nil)[:REPORT_DATA_SIZE])

    _, _, errno := syscall.Syscall(syscall.SYS_IOCTL,
        fd.Fd(), TDX_CMD_GET_REPORT0,
        uintptr(unsafe.Pointer(&req)))
    if errno != 0 {
        return nil, fmt.Errorf("ioctl TDX_CMD_GET_REPORT0: %w", errno)
    }
    return req.TdReport[:], nil
}

// VerifyReportData checks that the report data matches the expected nonce hash.
func VerifyReportData(report []byte, nonce []byte) bool {
    if len(report) < REPORT_DATA_SIZE {
        return false
    }
    h := sha512.New()
    h.Write(nonce)
    expected := hex.EncodeToString(h.Sum(nil)[:REPORT_DATA_SIZE])
    actual   := hex.EncodeToString(report[:REPORT_DATA_SIZE])
    return expected == actual
}
```

---

## Decision Matrix

| Scenario | Controls | Priority |
|---|---|---|
| Public-facing container (K8s) | `CAP_DROP ALL` + `RuntimeDefault` seccomp + `readOnlyRootFilesystem` + non-root UID | Mandatory |
| Privileged system daemon (needs raw sockets) | Capabilities: `CAP_NET_RAW` only + seccomp allowlist + SELinux targeted policy | High |
| Untrusted code execution (sandbox / CI runner) | seccomp strict + Landlock + User namespace + `NO_NEW_PRIVS` + no network namespace | Critical |
| High-security database server | SELinux enforcing + sysctl hardening (`ptrace_scope=2`) + kernel lockdown mode | High |
| Embedded/IoT with minimal kernel | Landlock (no SELinux overhead) + capabilities drop + `init_on_alloc=1` | Medium |
| Multi-tenant SaaS (VM-level isolation) | gVisor (ptrace/KVM mode) or Kata Containers + seccomp + AppArmor inside VM | Critical |
| Confidential workload (regulated data) | AMD SEV-SNP or Intel TDX + remote attestation + encrypted swap | High |
| CI/CD pipeline (build containers) | `--security-opt no-new-privileges` + `seccomp=builtin` + rootless Podman | Medium |
| Legacy monolith (cannot modify binary) | AppArmor profile (pathname-based) + systemd hardening unit | Medium |

---

## Proficiency Levels

### Novice
- Understands kernel/user space boundary and why root is dangerous
- Reads Docker `--cap-drop` and `--cap-add` docs; applies them
- Knows SELinux states (enforcing/permissive/disabled); can toggle without breaking system
- Applies Kubernetes `securityContext.runAsNonRoot` and `allowPrivilegeEscalation: false`

### Intermediate
- Writes custom seccomp profiles with `libseccomp` or `seccomp-bpf` JSON (OCI format)
- Diagnoses SELinux AVC denials with `audit2why`; generates allow rules with `audit2allow`
- Applies systemd `CapabilityBoundingSet`, `SystemCallFilter`, `ProtectSystem=strict`
- Implements Landlock sandbox for a Go or C service
- Uses `capsh`, `pmap`, `/proc/PID/status` to audit live process privilege

### Advanced
- Writes `NO_NEW_PRIVS`-aware capability drop code for production C/Go services
- Authors SELinux `.te` policy modules; compiles and installs with `semodule`
- Deploys eBPF programs (BCC/libbpf) for runtime syscall auditing
- Interprets kernel oops with KASAN/UBSAN output; identifies security impact
- Tunes sysctl hardening parameters for CIS Benchmark Level 2 compliance
- Configures Falco rules for container runtime threat detection

### Expert
- Designs multi-layer kernel security architecture for an OS distribution or SaaS platform
- Contributes LSM hooks or seccomp improvements to the Linux kernel
- Implements remote attestation flow using TDX or SEV-SNP for confidential workloads
- Evaluates kernel CFI (KCFI, FineIBT) effectiveness against ROP/JOP chains
- Performs kernel exploit analysis (UAF, heap spray, ret2usr) to validate defence depth
- Architects a zero-trust kernel network stack with eBPF + Cilium for east-west traffic

---

## AI Prompts

```
You are a Linux kernel security expert. I have a containerised Go HTTP service
running in Kubernetes. Walk me through the exact set of seccomp syscalls it
needs for normal operation (TLS, outbound DNS, file config reads) and produce
a minimal OCI seccomp JSON profile. Explain why each syscall is included.
```

```
Acting as a Red Team engineer: what are the top 5 container escape techniques
that work against a default Docker deployment without seccomp customisation?
For each, state the CVE or technique name, the kernel primitive exploited,
and the specific seccomp rule or sysctl that would block it.
```

```
Explain the difference between SELinux type enforcement and AppArmor
pathname-based confinement. Given that I'm running Ubuntu 24.04 (AppArmor
default) and need to confine a Node.js microservice that reads config from
/etc/app/, writes logs to /var/log/app/, and opens TCP sockets, write the
AppArmor profile and explain each rule.
```

```
I need to implement a Landlock sandbox in Rust for a PDF rendering service.
The service reads PDFs from /tmp/uploads/, writes rendered PNGs to /tmp/output/,
and makes no network calls. Show me the Rust FFI bindings to the three Landlock
syscalls and the complete sandbox setup code. Explain the kernel version
requirements and graceful fallback for older kernels.
```

```
Describe the AMD SEV-SNP remote attestation flow end to end: from VM boot,
through the attestation report request, to the relying party verification.
What is measured in the VCEK certificate chain, and how does the platform
owner verify the workload has not been tampered with?
```

---

## References

- **Linux Kernel Security** — `Documentation/security/` in kernel source tree
- **Linux Capabilities** — `man 7 capabilities`; `man 8 capsh`
- **libseccomp** — https://github.com/seccomp/libseccomp; `man 3 seccomp_init`
- **Landlock LSM** — `Documentation/userspace-api/landlock.rst`; kernel ≥ 5.13
- **SELinux Project** — https://github.com/SELinuxProject; `man 8 semanage`
- **AppArmor** — https://apparmor.net; `man 5 apparmor.d`
- **Kernel Self-Protection Project (KSPP)** — https://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project
- **CIS Benchmarks** — Level 2 Linux (access via CIS website)
- **gVisor** — https://gvisor.dev — application kernel for container sandboxing
- **Kata Containers** — https://katacontainers.io — VM-based container runtime
- **Falco** — https://falco.org — eBPF-based runtime security
- **Cilium** — https://cilium.io — eBPF network security + policy enforcement
- **AMD SEV-SNP** — AMD64 Architecture Programmer's Manual Vol. 2, §15
- **Intel TDX** — Intel TDX Module Architecture Specification (intel.com)
- **NVD CVE-2022-0847 (Dirty Pipe)** — case study for kernel privilege escalation via pipe splice
- **Phrack #68** — "Exploiting the Linux Kernel via Package Managers" — real-world kernel attack chains
