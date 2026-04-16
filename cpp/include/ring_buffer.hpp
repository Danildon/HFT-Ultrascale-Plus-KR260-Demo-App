#pragma once
// ring_buffer.hpp
// Single-Producer Single-Consumer (SPSC) lock-free ring buffer.
//
// Design rationale:
//   In a typical HFT pipeline the market data feed thread (producer) and the
//   strategy/order-management thread (consumer) are the only two that touch
//   the order queue.  SPSC removes all CAS loops — the producer only writes
//   `head_`, the consumer only writes `tail_`, and each only *reads* the
//   other.  This means a single atomic store/load per operation, which on
//   x86 TSO is just a MOV.
//
//   The critical cache-line discipline:
//   - `head_` and `tail_` are on *separate* cache lines.  If they shared one,
//     every push AND every pop would bounce a single line between producer and
//     consumer cores — "false sharing" that serialises the two threads.
//   - The data buffer `buf_` is on its own set of lines; it is written once
//     by the producer and read once by the consumer so there is no sharing.
//
//   Memory order choices:
//   - push():  store to buf_[head] with release; then store head_ with release.
//     The release on head_ ensures the payload write is visible before the
//     index update.
//   - pop():   load tail_ with relaxed (only the consumer writes it), load
//     head_ with acquire (pairs with the release in push()).

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>

namespace hft {

static constexpr std::size_t CACHE_LINE = 64;

template <typename T, std::size_t Capacity>
class RingBuffer {
    static_assert((Capacity & (Capacity - 1)) == 0,
        "Capacity must be a power of two (enables cheap modulo via bitmask)");
    static_assert(std::is_trivially_copyable_v<T>);

    static constexpr std::size_t MASK = Capacity - 1;

public:
    RingBuffer() = default;

    // Non-copyable, non-movable (contains atomics)
    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    // -----------------------------------------------------------------------
    // Producer side
    // -----------------------------------------------------------------------

    /// Try to push one item.  Returns false if the buffer is full.
    /// Must be called from a SINGLE producer thread only.
    [[nodiscard]]
    __attribute__((always_inline))
    bool push(const T& item) noexcept {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t next_h = (h + 1) & MASK;

        // Full check: if the slot the head is about to occupy is the tail,
        // we would overwrite unread data.
        if (__builtin_expect(
                next_h == tail_.load(std::memory_order_acquire), 0))
            return false;

        buf_[h] = item;                                          // write data
        head_.store(next_h, std::memory_order_release);          // publish
        return true;
    }

    // -----------------------------------------------------------------------
    // Consumer side
    // -----------------------------------------------------------------------

    /// Try to pop one item.  Returns std::nullopt if the buffer is empty.
    /// Must be called from a SINGLE consumer thread only.
    [[nodiscard]]
    __attribute__((always_inline))
    std::optional<T> pop() noexcept {
        const std::size_t t = tail_.load(std::memory_order_relaxed);

        if (__builtin_expect(
                t == head_.load(std::memory_order_acquire), 0))
            return std::nullopt;   // empty

        T item = buf_[t];                                        // read data
        tail_.store((t + 1) & MASK, std::memory_order_release); // consume
        return item;
    }

    /// Approximate size (may be stale by one element due to relaxed reads).
    std::size_t size_approx() const noexcept {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t t = tail_.load(std::memory_order_relaxed);
        return (h - t) & MASK;
    }

    bool empty() const noexcept {
        return head_.load(std::memory_order_relaxed) ==
               tail_.load(std::memory_order_relaxed);
    }

private:
    // Producer cache line: only the producer writes head_
    alignas(CACHE_LINE) std::atomic<std::size_t> head_{0};

    // Consumer cache line: only the consumer writes tail_
    alignas(CACHE_LINE) std::atomic<std::size_t> tail_{0};

    // Data buffer: separate lines from the index variables
    alignas(CACHE_LINE) T buf_[Capacity]{};
};

} // namespace hft
