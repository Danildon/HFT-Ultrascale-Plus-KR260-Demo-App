// =============================================================================
// tob_axi_driver.hpp
// Userspace driver for reading the TOB AXI4-Lite register file from the
// Cortex-A53 APU on the Kria K26 SOM.
//
// Mechanism: /dev/mem + mmap()
//   Linux exposes physical memory (including FPGA AXI-mapped registers) via
//   /dev/mem.  We mmap() the physical base address of the AXI4-Lite slave,
//   which maps the FPGA register space into our process's virtual address space.
//   After mmap(), reading a register is a single 32-bit load (LDR instruction)
//   — no syscall, no kernel involvement, ~10–20 ns round-trip.
//
// Base address:
//   Set in Vivado Address Editor when building the block design.
//   Default: 0xA000_0000 (GP0 AXI slave region on Zynq US+)
//   Check with: cat /proc/iomem | grep a000
//
// Security:
//   /dev/mem access requires root or the 'kmem' group.
//   On Kria Ubuntu: sudo ./hft_bench  OR  sudo adduser $USER kmem
//
// Alternative (safer): write a UIO (Userspace I/O) kernel driver or use
//   the Xilinx xdma driver.  For a demo, /dev/mem is fine.
// =============================================================================

#pragma once

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>

// Linux-specific
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "order_book.hpp"      // for TopOfBook, PriceLevel

namespace hft {

// ---------------------------------------------------------------------------
// Register offsets (must match tob_axi_lite.sv)
// ---------------------------------------------------------------------------
namespace reg {
    constexpr uint32_t STATUS       = 0x00;
    constexpr uint32_t TOB_CHANGED  = 0x04;
    constexpr uint32_t MSG_CNT_LO   = 0x08;
    constexpr uint32_t MSG_CNT_HI   = 0x0C;
    constexpr uint32_t BID_PRICE_LO = 0x10;
    constexpr uint32_t BID_PRICE_HI = 0x14;
    constexpr uint32_t BID_QTY      = 0x18;
    constexpr uint32_t ASK_PRICE_LO = 0x1C;
    constexpr uint32_t ASK_PRICE_HI = 0x20;
    constexpr uint32_t ASK_QTY      = 0x24;
    constexpr uint32_t SPREAD_LO    = 0x28;
    constexpr uint32_t SPREAD_HI    = 0x2C;
}

// ---------------------------------------------------------------------------
// TobAxiDriver: maps and reads the AXI4-Lite TOB register file
// ---------------------------------------------------------------------------
class TobAxiDriver {
public:
    /// base_addr: physical address of the AXI4-Lite slave (from Vivado Address Editor)
    /// map_size:  total bytes to map (at least 0x30 + 4 = 52 bytes; map 4KB aligned)
    explicit TobAxiDriver(uintptr_t base_addr = 0xA000'0000UL,
                          std::size_t map_size = 4096) {
        fd_ = open("/dev/mem", O_RDWR | O_SYNC);
        if (fd_ < 0)
            throw std::runtime_error(
                "Cannot open /dev/mem — run as root or add user to 'kmem' group.\n"
                "  sudo ./hft_bench\n"
                "  OR: sudo adduser $USER kmem && newgrp kmem");

        map_base_ = mmap(nullptr, map_size,
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED,
                         fd_, static_cast<off_t>(base_addr));
        if (map_base_ == MAP_FAILED) {
            close(fd_);
            throw std::runtime_error("mmap /dev/mem failed: " +
                                      std::string(strerror(errno)));
        }
        map_size_ = map_size;
        base_     = reinterpret_cast<volatile uint32_t*>(map_base_);
    }

    ~TobAxiDriver() {
        if (map_base_ && map_base_ != MAP_FAILED)
            munmap(map_base_, map_size_);
        if (fd_ >= 0)
            close(fd_);
    }

    // Non-copyable
    TobAxiDriver(const TobAxiDriver&) = delete;
    TobAxiDriver& operator=(const TobAxiDriver&) = delete;

    // -----------------------------------------------------------------------
    // Register accessors — each is a single 32-bit AXI read (~10–20 ns)
    // -----------------------------------------------------------------------

    __attribute__((always_inline))
    uint32_t read_reg(uint32_t offset) const noexcept {
        // ARM64: volatile load ensures the compiler doesn't elide repeated reads.
        // The CPU issues a device load to the AXI interconnect.
        return base_[offset / 4];
    }

    void write_reg(uint32_t offset, uint32_t value) noexcept {
        base_[offset / 4] = value;
        // DSB ensures the write reaches the FPGA before we continue
        __asm__ volatile("dsb sy" ::: "memory");
    }

    // -----------------------------------------------------------------------
    // High-level accessors
    // -----------------------------------------------------------------------

    bool tob_valid()    const noexcept { return read_reg(reg::STATUS) & 0x1; }
    bool crossed_book() const noexcept { return read_reg(reg::STATUS) & 0x2; }
    bool parse_error()  const noexcept { return read_reg(reg::STATUS) & 0x4; }

    /// Returns 1 if TOB changed since last call; clears the latch on read.
    bool tob_changed_and_clear() const noexcept {
        return read_reg(reg::TOB_CHANGED) & 0x1;
    }

    uint64_t msg_count() const noexcept {
        uint64_t lo = read_reg(reg::MSG_CNT_LO);
        uint64_t hi = read_reg(reg::MSG_CNT_HI);
        return (hi << 32) | lo;
    }

    /// Read a consistent top-of-book snapshot.
    /// We read twice and check tob_changed to detect a mid-read update.
    /// In practice updates are rare relative to read frequency.
    TopOfBook read_tob(double tick_size = 0.01) const noexcept {
        TopOfBook tob{};
        int retries = 0;

        do {
            (void)tob_changed_and_clear();   // clear stale flag

            uint64_t bid_lo  = read_reg(reg::BID_PRICE_LO);
            uint64_t bid_hi  = read_reg(reg::BID_PRICE_HI);
            uint32_t bid_qty = read_reg(reg::BID_QTY);
            uint64_t ask_lo  = read_reg(reg::ASK_PRICE_LO);
            uint64_t ask_hi  = read_reg(reg::ASK_PRICE_HI);
            uint32_t ask_qty = read_reg(reg::ASK_QTY);

            // If TOB changed during our reads, retry once
            if (tob_changed_and_clear() && retries++ < 1) continue;

            tob.bid.price    = static_cast<Price>((bid_hi << 32) | bid_lo);
            tob.bid.quantity = static_cast<Quantity>(bid_qty);
            tob.ask.price    = static_cast<Price>((ask_hi << 32) | ask_lo);
            tob.ask.quantity = static_cast<Quantity>(ask_qty);
            break;
        } while (true);

        return tob;
    }

    /// Clear the sticky parse_error flag
    void clear_parse_error() noexcept {
        write_reg(reg::STATUS, 0x4);  // write bit 2 to clear
    }

private:
    int                   fd_       = -1;
    void*                 map_base_ = nullptr;
    std::size_t           map_size_ = 0;
    volatile uint32_t*    base_     = nullptr;
};

} // namespace hft
