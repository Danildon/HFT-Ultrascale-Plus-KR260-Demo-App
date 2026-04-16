#pragma once
// feed_handler.hpp
// Binary market-data decoder for a NASDAQ ITCH 5.0-inspired protocol.
//
// Why binary and not FIX?
//   ASCII FIX requires string scanning (strchr, atoi) on every field.
//   Binary protocols encode fields at fixed byte offsets — the parser is
//   just a series of memory reads + byte-swaps.  This cuts parsing latency
//   from ~500 ns (simple FIX) to ~20–50 ns for an equivalent binary message.
//
// Message types handled:
//   'A' = Add Order       (price, qty, side, order_ref)
//   'U' = Order Update    (order_ref, new_qty)
//   'D' = Delete Order    (order_ref)
//   'E' = Execute         (order_ref, executed_qty)
//   'P' = Trade (non-displayed)

#include <arpa/inet.h>    // ntohl, ntohs (network → host byte order)
#include <cstdint>
#include <cstring>
#include <functional>
#include <unordered_map>

#include "order_book.hpp"

namespace hft {

// ---------------------------------------------------------------------------
// Wire format for each message type (packed, no padding)
// All multi-byte fields are network byte order (big-endian)
// ---------------------------------------------------------------------------
#pragma pack(push, 1)

struct MsgAddOrder {
    char     msg_type;      // 'A'
    uint64_t timestamp_ns;  // ns since midnight
    uint64_t order_ref;     // unique order reference
    char     side;          // 'B' or 'S'
    uint32_t quantity;
    int64_t  price;         // fixed-point ticks
};

struct MsgOrderUpdate {
    char     msg_type;      // 'U'
    uint64_t timestamp_ns;
    uint64_t order_ref;
    uint32_t new_quantity;
};

struct MsgDeleteOrder {
    char     msg_type;      // 'D'
    uint64_t timestamp_ns;
    uint64_t order_ref;
};

struct MsgExecute {
    char     msg_type;      // 'E'
    uint64_t timestamp_ns;
    uint64_t order_ref;
    uint32_t executed_qty;
};

struct MsgTrade {
    char     msg_type;      // 'P'
    uint64_t timestamp_ns;
    char     side;
    uint32_t quantity;
    int64_t  price;
};

#pragma pack(pop)

// ---------------------------------------------------------------------------
// Resting order record (tracked by the feed handler, not the order book)
// Side is stored as uint8_t to avoid a dependency on OrderBook's Capacity
// template parameter — OrderBook<256>::Side and OrderBook<8192>::Side are
// distinct types even though they share the same underlying values.
// ---------------------------------------------------------------------------
struct RestingOrder {
    Price    price;
    Quantity quantity;
    uint8_t  side;   // 0 = Bid, 1 = Ask  (matches OrderBook::Side enum values)
};

// ---------------------------------------------------------------------------
// FeedHandler: decodes a stream of binary messages and updates an OrderBook
// ---------------------------------------------------------------------------
template <std::size_t BookCapacity = 8192>
class FeedHandler {
    using Book = OrderBook<BookCapacity>;
    using Side = typename Book::Side;

public:
    // Callback types the strategy layer can register
    using TopOfBookCallback = std::function<void(const TopOfBook&, uint64_t ts_ns)>;
    using TradeCallback     = std::function<void(Price, Quantity, Side, uint64_t ts_ns)>;

    explicit FeedHandler(Book& book) : book_(book) {}

    void on_top_of_book(TopOfBookCallback cb) { tob_cb_  = std::move(cb); }
    void on_trade      (TradeCallback cb)     { trade_cb_ = std::move(cb); }

    // ------------------------------------------------------------------
    // Process one raw message buffer.
    // msg must point to at least msg_len bytes; the caller owns the buffer.
    // Returns true if a top-of-book change was produced.
    // ------------------------------------------------------------------
    bool process(const uint8_t* msg, std::size_t msg_len) noexcept {
        if (__builtin_expect(msg_len < 1, 0)) return false;

        const char type = static_cast<char>(msg[0]);
        bool tob_changed = false;

        switch (type) {
        case 'A': tob_changed = handle_add   (msg, msg_len); break;
        case 'U': tob_changed = handle_update (msg, msg_len); break;
        case 'D': tob_changed = handle_delete (msg, msg_len); break;
        case 'E': tob_changed = handle_execute(msg, msg_len); break;
        case 'P': handle_trade(msg, msg_len);                 break;
        default:  ++stats_.unknown_msgs;                      break;
        }

        if (tob_changed && tob_cb_) {
            tob_cb_(book_.top_of_book_snapshot(), last_ts_ns_);
        }

        return tob_changed;
    }

    struct Stats {
        uint64_t add_msgs     = 0;
        uint64_t update_msgs  = 0;
        uint64_t delete_msgs  = 0;
        uint64_t execute_msgs = 0;
        uint64_t trade_msgs   = 0;
        uint64_t unknown_msgs = 0;
        uint64_t tob_changes  = 0;
    };
    const Stats& stats() const noexcept { return stats_; }

private:

    // -------------------------------------------------------
    // Byte-swap helpers (network → host, inlined)
    // -------------------------------------------------------
    static uint64_t be64(const void* p) noexcept {
        uint64_t v; memcpy(&v, p, 8); return __builtin_bswap64(v);
    }
    static uint32_t be32(const void* p) noexcept {
        uint32_t v; memcpy(&v, p, 4); return __builtin_bswap32(v);
    }
    static int64_t be64s(const void* p) noexcept {
        return static_cast<int64_t>(be64(p));
    }

    // -------------------------------------------------------
    // Message handlers — each reads directly from the raw buffer
    // without copying into a struct (avoids an extra memcpy)
    // -------------------------------------------------------
    bool handle_add(const uint8_t* m, std::size_t len) noexcept {
        if (__builtin_expect(len < sizeof(MsgAddOrder), 0)) return false;
        ++stats_.add_msgs;

        uint64_t order_ref = be64(m + 9);   // offset after msg_type(1) + ts(8)
        char     side_c    = static_cast<char>(m[17]);
        uint32_t qty       = be32(m + 18);
        int64_t  price     = be64s(m + 22);
        last_ts_ns_        = be64(m + 1);

        Side side = (side_c == 'B') ? Side::Bid : Side::Ask;

        // Track the order for later updates/cancels
        orders_[order_ref] = RestingOrder{price, static_cast<Quantity>(qty), static_cast<uint8_t>(side)};

        book_.update_level(side, price, static_cast<Quantity>(qty), 1);
        ++stats_.tob_changes;
        return true;
    }

    bool handle_update(const uint8_t* m, std::size_t len) noexcept {
        if (__builtin_expect(len < sizeof(MsgOrderUpdate), 0)) return false;
        ++stats_.update_msgs;

        uint64_t order_ref  = be64(m + 9);
        uint32_t new_qty    = be32(m + 17);
        last_ts_ns_         = be64(m + 1);

        auto it = orders_.find(order_ref);
        if (__builtin_expect(it == orders_.end(), 0)) return false;

        RestingOrder& o   = it->second;
        Quantity delta    = static_cast<Quantity>(new_qty) - o.quantity;
        o.quantity        = static_cast<Quantity>(new_qty);

        if (o.quantity <= 0) {
            book_.remove_level(static_cast<Side>(o.side), o.price);
            orders_.erase(it);
        } else {
            book_.update_level(static_cast<Side>(o.side), o.price, delta, 0);
        }
        ++stats_.tob_changes;
        return true;
    }

    bool handle_delete(const uint8_t* m, std::size_t len) noexcept {
        if (__builtin_expect(len < sizeof(MsgDeleteOrder), 0)) return false;
        ++stats_.delete_msgs;

        uint64_t order_ref = be64(m + 9);
        last_ts_ns_        = be64(m + 1);

        auto it = orders_.find(order_ref);
        if (__builtin_expect(it == orders_.end(), 0)) return false;

        RestingOrder& o = it->second;
        book_.update_level(static_cast<Side>(o.side), o.price, -o.quantity, -1);
        orders_.erase(it);
        ++stats_.tob_changes;
        return true;
    }

    bool handle_execute(const uint8_t* m, std::size_t len) noexcept {
        if (__builtin_expect(len < sizeof(MsgExecute), 0)) return false;
        ++stats_.execute_msgs;

        uint64_t order_ref   = be64(m + 9);
        uint32_t exec_qty    = be32(m + 17);
        last_ts_ns_          = be64(m + 1);

        auto it = orders_.find(order_ref);
        if (__builtin_expect(it == orders_.end(), 0)) return false;

        RestingOrder& o     = it->second;
        Quantity executed   = static_cast<Quantity>(exec_qty);
        o.quantity         -= executed;

        if (o.quantity <= 0) {
            book_.remove_level(static_cast<Side>(o.side), o.price);
            orders_.erase(it);
        } else {
            book_.update_level(static_cast<Side>(o.side), o.price, -executed, 0);
        }
        ++stats_.tob_changes;
        return true;
    }

    void handle_trade(const uint8_t* m, std::size_t len) noexcept {
        if (__builtin_expect(len < sizeof(MsgTrade), 0)) return;
        ++stats_.trade_msgs;

        char     side_c  = static_cast<char>(m[9]);
        uint32_t qty     = be32(m + 10);
        int64_t  price   = be64s(m + 14);
        last_ts_ns_      = be64(m + 1);

        if (trade_cb_) {
            Side side = (side_c == 'B') ? Side::Bid : Side::Ask;
            trade_cb_(price, static_cast<Quantity>(qty), side, last_ts_ns_);
        }
    }

    Book& book_;

    // Resting order map: order_ref → RestingOrder
    // In production this would be a flat hash map (e.g. Robin Hood) for
    // better cache behaviour on the ~40-byte entries.
    std::unordered_map<uint64_t, RestingOrder> orders_;

    TopOfBookCallback tob_cb_;
    TradeCallback     trade_cb_;
    Stats             stats_{};
    uint64_t          last_ts_ns_ = 0;
};

// ---------------------------------------------------------------------------
// MessageBuilder: helper to construct binary test messages
// ---------------------------------------------------------------------------
namespace msg {

inline void write_be64(uint8_t* dst, uint64_t v) {
    v = __builtin_bswap64(v); memcpy(dst, &v, 8);
}
inline void write_be32(uint8_t* dst, uint32_t v) {
    v = __builtin_bswap32(v); memcpy(dst, &v, 4);
}

/// Build an Add Order message into buf (must be >= 30 bytes).
inline std::size_t build_add(uint8_t* buf, uint64_t ts_ns, uint64_t order_ref,
                              char side, uint32_t qty, int64_t price_ticks) {
    buf[0] = 'A';
    write_be64(buf + 1,  ts_ns);
    write_be64(buf + 9,  order_ref);
    buf[17] = static_cast<uint8_t>(side);
    write_be32(buf + 18, qty);
    write_be64(buf + 22, static_cast<uint64_t>(price_ticks));
    return 30;
}

inline std::size_t build_delete(uint8_t* buf, uint64_t ts_ns, uint64_t order_ref) {
    buf[0] = 'D';
    write_be64(buf + 1, ts_ns);
    write_be64(buf + 9, order_ref);
    return 17;
}

inline std::size_t build_execute(uint8_t* buf, uint64_t ts_ns,
                                  uint64_t order_ref, uint32_t exec_qty) {
    buf[0] = 'E';
    write_be64(buf + 1,  ts_ns);
    write_be64(buf + 9,  order_ref);
    write_be32(buf + 17, exec_qty);
    return 21;
}

} // namespace msg
} // namespace hft
