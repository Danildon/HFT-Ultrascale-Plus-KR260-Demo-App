#pragma once
// order_book.hpp
// Cache-optimised L2 order book (price-level aggregated).
//
// Design decisions explained:
//
// 1. Array-indexed by price tick, not std::map
//    std::map<Price, Level> has O(log N) insert/erase plus pointer-chasing
//    cache misses.  For liquid instruments with a tight spread, the active
//    portion of the book fits in a contiguous price window.  We maintain a
//    circular array of PriceLevels indexed by (price_tick % DEPTH).  Random
//    access to any level is O(1) with a single cache-line touch for the level.
//
// 2. Seqlock for concurrent reads
//    The strategy thread needs to read the top-of-book without blocking the
//    feed thread that updates it.  A mutex would add ~50 ns.  A seqlock lets
//    the writer proceed unconditionally; readers retry only on the rare case
//    of a mid-update read.  For a top-of-book snapshot this retry rate is
//    negligible in practice.
//
// 3. No heap allocation after construction
//    All PriceLevel storage is pre-allocated.  Zero dynamic allocation on the
//    update path means no allocator contention and no unpredictable latency
//    spikes from malloc.
//
// 4. Fixed-point price representation
//    Floating-point prices invite precision bugs and slower comparisons.
//    We represent price as int64 ticks (e.g. price_ticks * 1e-4 = USD price).
//    The tick size is a construction parameter.

#include <atomic>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace hft {

// ---------------------------------------------------------------------------
// Fixed-point price: ticks. 1 tick = tick_size USD.
// Using int64 gives us sufficient range without FP noise.
// ---------------------------------------------------------------------------
using Price    = int64_t;
using Quantity = int64_t;

static constexpr Price NULL_PRICE = std::numeric_limits<Price>::min();

inline constexpr Price dollars_to_ticks(double usd, double tick_size) {
    return static_cast<Price>(usd / tick_size + 0.5);
}

inline constexpr double ticks_to_dollars(Price ticks, double tick_size) {
    return static_cast<double>(ticks) * tick_size;
}

// ---------------------------------------------------------------------------
// PriceLevel: one aggregated price point in the book
// ---------------------------------------------------------------------------
struct PriceLevel {
    Price    price    = NULL_PRICE;
    Quantity quantity = 0;
    int32_t  orders   = 0;     // count of resting orders at this level

    bool empty() const noexcept { return quantity <= 0; }
};

// ---------------------------------------------------------------------------
// Seqlock: writer-side increment, readers spin on odd sequence number.
// The seqlock here is a classic Lamport-style implementation:
//   writer: increment seq (odd), write data, increment seq (even)
//   reader: read seq, read data, read seq again; retry if odd or changed.
// ---------------------------------------------------------------------------
class Seqlock {
public:
    void write_begin() noexcept {
        seq_.fetch_add(1, std::memory_order_release);
        std::atomic_thread_fence(std::memory_order_release);
    }
    void write_end() noexcept {
        seq_.fetch_add(1, std::memory_order_release);
    }

    uint64_t read_begin() const noexcept {
        uint64_t s;
        do { s = seq_.load(std::memory_order_acquire); }
        while (s & 1); // spin while writer holds the lock (odd)
        return s;
    }
    bool read_retry(uint64_t s) const noexcept {
        std::atomic_thread_fence(std::memory_order_acquire);
        return seq_.load(std::memory_order_relaxed) != s;
    }

private:
    alignas(64) std::atomic<uint64_t> seq_{0};
};

// ---------------------------------------------------------------------------
// TopOfBook: the best bid and ask, protected by a seqlock for lock-free reads
// ---------------------------------------------------------------------------
struct TopOfBook {
    PriceLevel bid;   // best (highest) bid
    PriceLevel ask;   // best (lowest) ask

    bool crossed() const noexcept {
        return bid.price != NULL_PRICE &&
               ask.price != NULL_PRICE &&
               bid.price >= ask.price;
    }

    double mid_price(double tick_size) const noexcept {
        if (bid.price == NULL_PRICE || ask.price == NULL_PRICE) return 0.0;
        return ticks_to_dollars(bid.price + ask.price, tick_size) / 2.0;
    }

    double spread_ticks() const noexcept {
        if (bid.price == NULL_PRICE || ask.price == NULL_PRICE) return 0.0;
        return static_cast<double>(ask.price - bid.price);
    }
};

// ---------------------------------------------------------------------------
// OrderBook
// ---------------------------------------------------------------------------
//  Capacity    — number of price slots per side (must be power-of-two)
//  tick_size   — USD value of one price tick (e.g. 0.01 for a 1-cent tick)
//
// Thread safety:
//   update_*  functions: single writer (feed handler thread)
//   top_of_book_snapshot(): safe to call from any thread concurrently

template <std::size_t Capacity = 8192>
class OrderBook {
    static_assert((Capacity & (Capacity - 1)) == 0);
    static constexpr std::size_t MASK = Capacity - 1;

public:
    enum class Side : uint8_t { Bid = 0, Ask = 1 };

    explicit OrderBook(std::string symbol, double tick_size)
        : symbol_(std::move(symbol)), tick_size_(tick_size) {
        reset();
    }

    // ------------------------------------------------------------------
    // Write path  (feed handler thread only)
    // ------------------------------------------------------------------

    /// Add or increase quantity at a price level.
    void update_level(Side side, Price price, Quantity qty_delta, int order_delta = 1) noexcept {
        PriceLevel* levels = (side == Side::Bid) ? bids_ : asks_;
        PriceLevel& lv = levels[price & MASK];

        if (lv.price == NULL_PRICE || lv.price == price) {
            lv.price     = price;
            lv.quantity += qty_delta;
            lv.orders   += order_delta;
            if (lv.quantity <= 0) {
                lv = PriceLevel{};   // level wiped out
            }
        }
        // Note: a collision (price & MASK hits a different price) is handled
        // by the caller passing a correct price window, or by resizing Capacity.

        refresh_top(side);
    }

    /// Remove a level entirely (e.g. order cancel removes last order).
    void remove_level(Side side, Price price) noexcept {
        PriceLevel* levels = (side == Side::Bid) ? bids_ : asks_;
        PriceLevel& lv = levels[price & MASK];
        if (lv.price == price) lv = PriceLevel{};
        refresh_top(side);
    }

    void reset() noexcept {
        for (auto& l : bids_) l = PriceLevel{};
        for (auto& l : asks_) l = PriceLevel{};
        tob_lock_.write_begin();
        tob_ = TopOfBook{};
        tob_lock_.write_end();
    }

    // ------------------------------------------------------------------
    // Read path  (any thread — seqlock-protected)
    // ------------------------------------------------------------------

    /// Take a consistent snapshot of the top-of-book.
    /// Lock-free, wait-free in the absence of writers.
    TopOfBook top_of_book_snapshot() const noexcept {
        TopOfBook snapshot;
        uint64_t seq;
        do {
            seq      = tob_lock_.read_begin();
            snapshot = tob_;            // struct copy (two PriceLevels = 48 B)
        } while (tob_lock_.read_retry(seq));
        return snapshot;
    }

    const std::string& symbol()    const noexcept { return symbol_; }
    double             tick_size() const noexcept { return tick_size_; }

private:
    // ------------------------------------------------------------------
    // Internal: re-scan the relevant side to find the new best.
    // Called after every update — O(Capacity) worst case but the active
    // portion is small and cache-resident in practice.
    // ------------------------------------------------------------------
    void refresh_top(Side side) noexcept {
        PriceLevel best{};

        if (side == Side::Bid) {
            for (std::size_t i = 0; i < Capacity; ++i) {
                if (!bids_[i].empty()) {
                    if (best.price == NULL_PRICE || bids_[i].price > best.price)
                        best = bids_[i];
                }
            }
        } else {
            for (std::size_t i = 0; i < Capacity; ++i) {
                if (!asks_[i].empty()) {
                    if (best.price == NULL_PRICE || asks_[i].price < best.price)
                        best = asks_[i];
                }
            }
        }

        tob_lock_.write_begin();
        if (side == Side::Bid) tob_.bid = best;
        else                   tob_.ask = best;
        tob_lock_.write_end();
    }

    std::string symbol_;
    double      tick_size_;

    // Each side gets its own cache-line region to avoid false sharing
    alignas(64) PriceLevel bids_[Capacity]{};
    alignas(64) PriceLevel asks_[Capacity]{};

    // Top-of-book snapshot protected by a seqlock
    mutable Seqlock  tob_lock_;
    TopOfBook        tob_{};
};

} // namespace hft
