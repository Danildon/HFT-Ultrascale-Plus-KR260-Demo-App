#pragma once
// latency_timer_arm64.hpp
// AArch64 cycle-accurate latency measurement for Cortex-A53 (Kria K26 SOM).
//
// Why not RDTSC?
//   RDTSC is x86-only. This file is the ARM64 equivalent.
//
// AArch64 system counter: CNTVCT_EL0
//   The virtual counter register CNTVCT_EL0 is the ARM architectural
//   equivalent of x86 TSC. Key properties:
//     - Read from userspace (no syscall) when CNTKCTL_EL1.EL0VCTEN=1,
//       which the Linux kernel sets at boot on all Cortex-A53 platforms.
//     - Runs at a fixed frequency (independent of CPU clock gating).
//       On Zynq UltraScale+ / Kria K26: typically 100 MHz (10 ns/tick).
//       Frequency is readable from CNTFRQ_EL0.
//     - 64-bit, monotonically increasing.
//     - NOT a cycle counter — it is a fixed-frequency wall clock.
//       On a 1.333 GHz A53, 1 CNTVCT tick = ~13.3 CPU cycles.
//       For nanosecond resolution this is fine (10 ns resolution at 100 MHz).
//
// Why not clock_gettime()?
//   On Linux/aarch64, clock_gettime(CLOCK_MONOTONIC) goes through the vDSO
//   and reads CNTVCT_EL0 internally — costing ~15–25 ns including the vDSO
//   call overhead.  Reading CNTVCT_EL0 directly costs ~5 ns.
//   For measuring 120–180 ns hot paths the vDSO overhead is still material.
//
// Memory barriers for ARM64:
//   Unlike x86's TSO (total store order) model, ARM has a weakly-ordered
//   memory model. We need explicit barriers to prevent the compiler and CPU
//   from reordering instructions around measurement points.
//
//   - ISB (Instruction Synchronization Barrier): flushes the pipeline,
//     ensuring all prior instructions have committed. Equivalent to x86 LFENCE
//     for instruction ordering. Costs ~3–5 ns.
//   - DSB SY (Data Synchronization Barrier): ensures all memory accesses
//     before it are complete. Stronger than ISB. Costs ~5–10 ns.
//
//   Pattern used (matches Intel's recommended RDTSC pattern):
//     start: ISB then CNTVCT_EL0   — prevent prior code bleeding into measurement
//     end:   DSB SY then CNTVCT_EL0 then ISB — wait for measured code to retire
//
// CNTVCT_EL0 enablement:
//   Verify with: grep . /sys/bus/platform/drivers/arm_arch_timer/*/cntkctl
//   Should show bit 1 set (EL0VCTEN). On Ubuntu/PetaLinux this is always set.
//   If not: echo 1 > /proc/sys/kernel/perf_user_access (alternate approach)

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <string>

namespace hft {

// ---------------------------------------------------------------------------
// ARM64 counter frequency (Hz)
// Read from the hardware register once at startup.
// ---------------------------------------------------------------------------
inline uint64_t read_cntfrq() {
    uint64_t freq;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
    return freq;
}

/// Returns ns per CNTVCT tick.  On Kria K26: 1 / 100,000,000 Hz = 10 ns/tick.
inline double ns_per_tick() {
    static const double ns = 1.0e9 / static_cast<double>(read_cntfrq());
    return ns;
}

inline double ticks_to_ns(uint64_t ticks) {
    return static_cast<double>(ticks) * ns_per_tick();
}

// ---------------------------------------------------------------------------
// Start and end sample — ARM64 equivalents of x86 RDTSC pattern
// ---------------------------------------------------------------------------

/// Take a start timestamp.
/// ISB ensures prior instructions complete before the counter read.
__attribute__((always_inline))
inline uint64_t start_sample() noexcept {
    __asm__ volatile("isb" ::: "memory");
    uint64_t t;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t) :: "memory");
    return t;
}

/// Take an end timestamp.
/// ISB flushes the instruction pipeline, ensuring the measured code has
/// retired before we read the counter.
/// We deliberately avoid DSB SY here — on Cortex-A53 it waits for ALL
/// outstanding memory accesses system-wide and costs thousands of cycles,
/// which would dwarf any sub-microsecond measurement. ISB is correct for
/// timing user-space computation (not MMIO).
__attribute__((always_inline))
inline uint64_t end_sample() noexcept {
    __asm__ volatile("isb" ::: "memory");
    uint64_t t;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t) :: "memory");
    return t;
}

// ---------------------------------------------------------------------------
// LatencyHistogram — identical API to the x86 version
// Only the unit conversion changes (ticks → ns via ns_per_tick())
// ---------------------------------------------------------------------------

template <std::size_t Capacity = 1'000'000>
class LatencyHistogram {
public:
    explicit LatencyHistogram(std::string name) : name_(std::move(name)) {
        samples_.fill(0);
        // Warm up the ns_per_tick() static initialiser now (not on first record)
        (void)ns_per_tick();
    }

    __attribute__((always_inline))
    void record(uint64_t ticks) noexcept {
        if (__builtin_expect(count_ < Capacity, 1))
            samples_[count_++] = ticks;
    }

    struct Stats {
        double min_ns, p50_ns, p90_ns, p99_ns, p999_ns, max_ns, mean_ns;
        std::size_t sample_count;
        double counter_freq_mhz;  // for reference
    };

    Stats compute() {
        assert(count_ > 0);
        std::sort(samples_.begin(), samples_.begin() + count_);

        auto pct = [&](double p) -> double {
            auto idx = static_cast<std::size_t>(p * (count_ - 1));
            return ticks_to_ns(samples_[idx]);
        };

        double sum = 0.0;
        for (std::size_t i = 0; i < count_; ++i)
            sum += ticks_to_ns(samples_[i]);

        return Stats{
            .min_ns           = ticks_to_ns(samples_[0]),
            .p50_ns           = pct(0.50),
            .p90_ns           = pct(0.90),
            .p99_ns           = pct(0.99),
            .p999_ns          = pct(0.999),
            .max_ns           = ticks_to_ns(samples_[count_ - 1]),
            .mean_ns          = sum / static_cast<double>(count_),
            .sample_count     = count_,
            .counter_freq_mhz = 1.0e3 / ns_per_tick(),
        };
    }

    const std::string& name()  const { return name_; }
    std::size_t        count() const { return count_; }

private:
    std::string name_;
    std::array<uint64_t, Capacity> samples_{};
    std::size_t count_ = 0;
};

} // namespace hft
