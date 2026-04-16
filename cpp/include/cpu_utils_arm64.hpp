#pragma once
// cpu_utils_arm64.hpp
// Thread affinity, memory locking, and barrier utilities for AArch64 / Cortex-A53.
//
// The Cortex-A53 on the Kria K26 SOM is a quad-core processor.
// Core allocation strategy for this project:
//
//   Core 0: OS + IRQs (leave alone — this is the boot core)
//   Core 1: Feed handler thread (pinned here, SCHED_FIFO)
//   Core 2: Strategy / TOB reader thread (pinned here, SCHED_FIFO)
//   Core 3: Available for logging / housekeeping
//
// To isolate cores 1 and 2 from the kernel scheduler, add to /etc/default/grub:
//   GRUB_CMDLINE_LINUX="isolcpus=1,2 nohz_full=1,2 rcu_nocbs=1,2"
// Then: sudo update-grub && reboot
//
// Note on IRQ affinity on Kria:
//   The GIC (Generic Interrupt Controller) on Zynq US+ routes most IRQs to
//   core 0 by default. Check /proc/interrupts and set_irq_affinity.sh if needed.

#include <cstring>
#include <stdexcept>
#include <string>

#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <unistd.h>

namespace hft::cpu {

// ---------------------------------------------------------------------------
// Pin the calling thread to a specific core
// ---------------------------------------------------------------------------
inline void pin_thread_to_core(int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    int rc = pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    if (rc != 0)
        throw std::runtime_error("pthread_setaffinity_np: " + std::string(strerror(rc)));
}

// ---------------------------------------------------------------------------
// SCHED_FIFO real-time priority
// Requires: sudo setcap cap_sys_nice+ep ./hft_bench
// Or run as root.  Kria Ubuntu allows setcap without full root.
// ---------------------------------------------------------------------------
inline void set_realtime_priority(int priority = 80) {
    struct sched_param param{};
    param.sched_priority = priority;
    int rc = pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
    if (rc != 0)
        throw std::runtime_error("pthread_setschedparam: " + std::string(strerror(rc)));
}

// ---------------------------------------------------------------------------
// Lock memory pages (prevent swap faults)
// ---------------------------------------------------------------------------
inline void lock_memory() {
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0)
        throw std::runtime_error("mlockall: " + std::string(strerror(errno)));
}

// ---------------------------------------------------------------------------
// Prefault memory: touch every page to trigger faults now, not during trading
// ---------------------------------------------------------------------------
inline void prefault(void* addr, std::size_t size) {
    volatile uint8_t* p = reinterpret_cast<volatile uint8_t*>(addr);
    for (std::size_t i = 0; i < size; i += 4096)
        p[i] = p[i];
}

// ---------------------------------------------------------------------------
// Huge pages on ARM64 Linux: 2 MB transparent huge pages or explicit hugetlbfs
// Kria Ubuntu supports both.  The MAP_HUGETLB flag works the same as x86.
// ---------------------------------------------------------------------------
inline void* alloc_hugepage(std::size_t size) {
    void* ptr = mmap(nullptr, size,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                     -1, 0);
    return (ptr == MAP_FAILED) ? nullptr : ptr;
}

inline void free_hugepage(void* ptr, std::size_t size) {
    munmap(ptr, size);
}

// ---------------------------------------------------------------------------
// Physical core count (A53 has 4 cores on K26)
// ---------------------------------------------------------------------------
inline int physical_core_count() {
    return static_cast<int>(sysconf(_SC_NPROCESSORS_ONLN));
}

// ---------------------------------------------------------------------------
// ARM64 memory barriers — used in hot paths instead of the x86 fence functions
//
// The C++ memory model covers most cases via std::atomic, but these are
// useful when interacting with the AXI-mapped FPGA registers (MMIO).
// MMIO accesses require explicit barriers because the compiler treats
// volatile MMIO pointers differently from regular memory.
// ---------------------------------------------------------------------------

/// Full system memory barrier (like x86 MFENCE).
/// Use after writing to FPGA MMIO registers to ensure the write is visible.
__attribute__((always_inline))
inline void dsb_sy() noexcept {
    __asm__ volatile("dsb sy" ::: "memory");
}

/// Load-acquire barrier — ensure prior loads complete before subsequent.
__attribute__((always_inline))
inline void dmb_ld() noexcept {
    __asm__ volatile("dmb ishld" ::: "memory");
}

/// Instruction synchronization barrier — flush CPU pipeline.
__attribute__((always_inline))
inline void isb() noexcept {
    __asm__ volatile("isb" ::: "memory");
}

} // namespace hft::cpu
