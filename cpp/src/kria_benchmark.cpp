// kria_benchmark.cpp
// Kria KR260 benchmark: measures three things together:
//
//   1. APU software path (Cortex-A53): feed decode + order book update
//      Using the same C++ code as the x86 benchmark, with ARM64 timer.
//
//   2. AXI register read latency: how fast can the APU read the FPGA's TOB?
//      This is the real "CPU↔FPGA interface" latency number.
//
//   3. Combined: software feed handler writes to software book;
//      FPGA book updated via hardware path;
//      APU polls AXI registers to see FPGA TOB — measures end-to-end.
//
// Run:
//   sudo ./hft_kria_bench                           # software path only
//   sudo ./hft_kria_bench --axi-base 0xa0000000     # + hardware path
//   sudo ./hft_kria_bench --core-feed 1 --core-reader 2 --realtime

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

// ARM64-specific headers (replaces x86 equivalents)
#include "latency_timer_arm64.hpp"
#include "cpu_utils_arm64.hpp"

// Platform-agnostic (compile clean on both x86 and ARM64)
#include "ring_buffer.hpp"
#include "order_book.hpp"
#include "feed_handler.hpp"

#ifdef HFT_PLATFORM_ARM64
  #include "tob_axi_driver.hpp"
#endif

using namespace hft;

struct Config {
    int      core_feed     = 1;
    int      core_reader   = 2;
    int      n_messages    = 500'000;
    bool     realtime      = false;
    bool     lock_mem      = false;
    bool     axi_bench     = false;
    uint64_t axi_base_addr = 0xA000'0000UL;
};

static Config parse_args(int argc, char** argv) {
    Config c;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--core-feed")   && i+1 < argc) c.core_feed   = atoi(argv[++i]);
        if (!strcmp(argv[i], "--core-reader") && i+1 < argc) c.core_reader = atoi(argv[++i]);
        if (!strcmp(argv[i], "--messages")    && i+1 < argc) c.n_messages  = atoi(argv[++i]);
        if (!strcmp(argv[i], "--realtime"))                   c.realtime    = true;
        if (!strcmp(argv[i], "--lock-mem"))                   c.lock_mem    = true;
        if (!strcmp(argv[i], "--axi-base")    && i+1 < argc) {
            c.axi_base_addr = static_cast<uint64_t>(
                strtoul(argv[++i], nullptr, 0));
            c.axi_bench = true;
        }
    }
    return c;
}

// ---------------------------------------------------------------------------
// Benchmark 1: Software feed processing on Cortex-A53
// ---------------------------------------------------------------------------
void bench_software_feed(const Config& cfg) {
    printf("\n[BENCHMARK 1] Software feed processing (Cortex-A53)\n");
    printf("  Core %d, %d messages\n", cfg.core_feed, cfg.n_messages);
    printf("  Timer: CNTVCT_EL0 @ %.1f MHz\n",
           1.0e3 / ns_per_tick());

    // Generate test messages (same as x86 benchmark)
    // Message batch: 200 unique price levels, order refs wrap every 200
    // so the FeedHandler's order map stays at <=200 entries (fits in L1 cache).
    // Without this, the map grows to n_messages entries causing cache thrash.
    struct MsgBatch {
        std::vector<std::vector<uint8_t>> messages;
        MsgBatch(int n) {
            messages.reserve(n);
            uint8_t buf[64];
            uint64_t ts = 34'200'000'000'000ULL;
            for (int i = 0; i < n; ++i) {
                bool is_bid = (i % 3 != 0);
                auto price  = static_cast<int64_t>(9990 + (i % 20));
                uint64_t ref = static_cast<uint64_t>(i % 200) + 1;  // wrap: keep map small
                auto len    = msg::build_add(buf, ts + i*1000, ref,
                                              is_bid ? 'B' : 'S',
                                              static_cast<uint32_t>(100 + (i%50)),
                                              price);
                messages.emplace_back(buf, buf + len);
            }
        }
    } batch(cfg.n_messages + 10000);

    OrderBook<256> book("AAPL", 0.01);
    FeedHandler     handler(book);
    LatencyHistogram<500'000> hist("feed_sw");

    // Warmup
    for (int i = 0; i < 10000; ++i) {
        const auto& m = batch.messages[i];
        handler.process(m.data(), m.size());
    }
    book.reset();

    // Measure
    for (int i = 0; i < cfg.n_messages; ++i) {
        const auto& m = batch.messages[i % (int)batch.messages.size()];
        uint64_t t0 = start_sample();
        handler.process(m.data(), m.size());
        uint64_t t1 = end_sample();
        hist.record(t1 - t0);
    }

    auto s = hist.compute();
    printf("  min:   %6.1f ns\n", s.min_ns);
    printf("  p50:   %6.1f ns\n", s.p50_ns);
    printf("  p99:   %6.1f ns\n", s.p99_ns);
    printf("  p99.9: %6.1f ns\n", s.p999_ns);
    printf("  max:   %6.1f ns\n", s.max_ns);
    printf("\n  Note: Cortex-A53 @ 1.333 GHz is ~4x slower than Xeon @ 3 GHz.\n"
           "  The FPGA data path (40 ns @ 200 MHz) handles time-critical work;\n"
           "  the A53 handles strategy logic where ~150 ns is acceptable.\n");
}

// ---------------------------------------------------------------------------
// Benchmark 2: AXI4-Lite register read latency
// ---------------------------------------------------------------------------
#ifdef HFT_PLATFORM_ARM64
void bench_axi_read(const Config& cfg) {
    printf("\n[BENCHMARK 2] AXI4-Lite TOB register read latency\n");
    printf("  Physical base: 0x%lx\n", cfg.axi_base_addr);

    TobAxiDriver axi(cfg.axi_base_addr);

    // Check hardware is up
    printf("  TOB valid:     %s\n", axi.tob_valid()    ? "YES" : "NO (book may be empty)");
    printf("  Crossed book:  %s\n", axi.crossed_book() ? "YES (ERROR)" : "NO");
    printf("  Parse errors:  %s\n", axi.parse_error()  ? "YES (check FPGA)" : "none");
    printf("  Messages seen: %lu\n", axi.msg_count());

    // Measure single register read latency
    LatencyHistogram<500'000> hist_single("axi_single");
    for (int i = 0; i < 500'000; ++i) {
        uint64_t t0 = start_sample();
        volatile uint32_t v = axi.read_reg(0x00);  // STATUS register
        uint64_t t1 = end_sample();
        (void)v;
        hist_single.record(t1 - t0);
    }
    {
        auto s = hist_single.compute();
        printf("\n  Single register read (32-bit AXI transaction):\n");
        printf("    p50:   %6.1f ns\n", s.p50_ns);
        printf("    p99:   %6.1f ns\n", s.p99_ns);
        printf("    p99.9: %6.1f ns\n", s.p999_ns);
    }

    // Measure full TOB snapshot (6 register reads: 2×price64 + 2×qty32)
    LatencyHistogram<500'000> hist_tob("axi_tob_snapshot");
    for (int i = 0; i < 500'000; ++i) {
        uint64_t t0 = start_sample();
        volatile auto tob = axi.read_tob(0.01);
        uint64_t t1 = end_sample();
        (void)tob;
        hist_tob.record(t1 - t0);
    }
    {
        auto s = hist_tob.compute();
        printf("\n  Full TOB snapshot (6 AXI reads: bid_price×2, bid_qty, ask_price×2, ask_qty):\n");
        printf("    p50:   %6.1f ns\n", s.p50_ns);
        printf("    p99:   %6.1f ns\n", s.p99_ns);
        printf("    p99.9: %6.1f ns\n", s.p999_ns);
        printf("\n  Interpretation:\n"
               "    This is the latency for the A53 to observe a FPGA TOB update.\n"
               "    Add this to the FPGA pipeline latency (40 ns @ 200 MHz) to get\n"
               "    the total time from market message arrival to strategy-visible TOB.\n");

        auto fpga_pipeline_ns = 40.0;  // 4 cycles × 10 ns
        printf("    FPGA pipeline:   %.0f ns\n", fpga_pipeline_ns);
        printf("    AXI read p50:    %.1f ns\n", s.p50_ns);
        printf("    ─────────────────────────\n");
        printf("    Total p50:       %.1f ns  (market data → A53 sees new price)\n",
               fpga_pipeline_ns + s.p50_ns);
    }
}
#endif

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Config cfg = parse_args(argc, argv);

    printf("╔══════════════════════════════════════════════════════╗\n");
    printf("║   HFT Order Book — Kria KR260 Benchmark             ║\n");
    printf("╚══════════════════════════════════════════════════════╝\n");
    printf("Platform: Cortex-A53 (AArch64)\n");
    printf("Timer:    CNTVCT_EL0 @ %.1f MHz\n", 1.0e3 / ns_per_tick());
    printf("CPUs:     %d\n\n", cpu::physical_core_count());

    cpu::pin_thread_to_core(cfg.core_feed);

    if (cfg.lock_mem) {
        try { cpu::lock_memory(); printf("[INFO] Memory locked.\n"); }
        catch (const std::exception& e) { printf("[WARN] %s\n", e.what()); }
    }
    if (cfg.realtime) {
        try { cpu::set_realtime_priority(); printf("[INFO] SCHED_FIFO set.\n"); }
        catch (const std::exception& e) { printf("[WARN] %s\n", e.what()); }
    }

    bench_software_feed(cfg);

#ifdef HFT_PLATFORM_ARM64
    if (cfg.axi_bench) {
        try {
            bench_axi_read(cfg);
        } catch (const std::exception& e) {
            printf("\n[ERROR] AXI bench failed: %s\n", e.what());
            printf("  Is the FPGA programmed? Is the AXI base address correct?\n");
            printf("  Check: cat /proc/iomem | grep a000\n");
        }
    } else {
        printf("\n[INFO] Re-run with --axi-base 0xa0000000 to benchmark FPGA AXI reads.\n");
        printf("       (Requires FPGA to be programmed with kr260_top.sv design)\n");
    }
#endif

    printf("\n[DONE]\n");
    return 0;
}
