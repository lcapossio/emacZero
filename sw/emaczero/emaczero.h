/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Leonardo Capossio - bard0 design
 *
 * emaczero.h — bare-metal driver header for eth_mac_sys.
 * Matches axilite_regs.v register layout (ADDR_WIDTH=8, 32-bit data).
 */

#ifndef EMACZERO_H
#define EMACZERO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Register offsets (byte addresses, word-aligned)
 * --------------------------------------------------------------------------- */
#define EMZ_REG_VERSION      0x00u
#define EMZ_REG_CTRL         0x04u
#define EMZ_REG_STATUS       0x08u
#define EMZ_REG_MAC_LO       0x0Cu
#define EMZ_REG_MAC_HI       0x10u
#define EMZ_REG_MDIO_CMD     0x14u
#define EMZ_REG_MDIO_WDATA   0x18u
#define EMZ_REG_MDIO_RDATA   0x1Cu
#define EMZ_REG_IRQ_EN       0x20u
#define EMZ_REG_IRQ_STATUS   0x24u
#define EMZ_REG_TX_FRAME_CNT 0x28u
#define EMZ_REG_TX_BYTE_CNT  0x2Cu
#define EMZ_REG_RX_FRAME_CNT 0x30u
#define EMZ_REG_RX_BYTE_CNT  0x34u
#define EMZ_REG_RX_ERR_CNT   0x38u
#define EMZ_REG_SCRATCH      0x3Cu
#define EMZ_REG_MCAST_LO     0x44u  /* only if MCAST_HASH_FILTER=1 */
#define EMZ_REG_MCAST_HI     0x48u
#define EMZ_REG_RX_ERR_ALIGN     0x4Cu
#define EMZ_REG_RX_ERR_OVERFLOW  0x50u
#define EMZ_REG_RX_ERR_OVERSIZE  0x54u
#define EMZ_REG_RX_BCAST         0x58u
#define EMZ_REG_RX_MCAST         0x5Cu
#define EMZ_REG_RX_SIZE_64       0x60u
#define EMZ_REG_RX_SIZE_65_127   0x64u
#define EMZ_REG_RX_SIZE_128_255  0x68u
#define EMZ_REG_RX_SIZE_256_511  0x6Cu
#define EMZ_REG_RX_SIZE_512_1023 0x70u
#define EMZ_REG_RX_SIZE_1024_1518 0x74u
#define EMZ_REG_RX_SIZE_JUMBO    0x78u
#define EMZ_REG_PAUSE_CTRL       0x84u
#define EMZ_REG_PAUSE_QUANTA     0x88u
#define EMZ_REG_PAUSE_RX_CNT     0x8Cu
#define EMZ_REG_PAUSE_TX_CNT     0x90u

/* Mirror of rtl/version.vh. build_and_test.py asserts these match. */
#define EMZ_VERSION_MAJOR        0u
#define EMZ_VERSION_MINOR        1u
#define EMZ_VERSION_ID           0x454Du  /* ASCII "EM" */
#define EMZ_VERSION_VALUE        ((EMZ_VERSION_MAJOR << 24) | \
                                  (EMZ_VERSION_MINOR << 16) | \
                                  EMZ_VERSION_ID)

/* ---------------------------------------------------------------------------
 * CTRL register fields
 * --------------------------------------------------------------------------- */
#define EMZ_CTRL_TX_EN        (1u << 0)
#define EMZ_CTRL_RX_EN        (1u << 1)
#define EMZ_CTRL_PROMISC      (1u << 2)
#define EMZ_CTRL_SPEED_SHIFT  3
#define EMZ_CTRL_SPEED_MASK   (0x3u << EMZ_CTRL_SPEED_SHIFT)
#define EMZ_CTRL_FULL_DUPLEX  (1u << 5)
#define EMZ_CTRL_JUMBO_EN     (1u << 6)
#define EMZ_CTRL_TX_CSUM_OFF  (1u << 7)
#define EMZ_CTRL_PASSTHROUGH  (1u << 8)

#define EMZ_SPEED_1G          0x0u
#define EMZ_SPEED_100M        0x1u
#define EMZ_SPEED_10M         0x2u

/* Reset default per axilite_regs.v: tx_en | rx_en | full_duplex */
#define EMZ_CTRL_DEFAULT (EMZ_CTRL_TX_EN | EMZ_CTRL_RX_EN | EMZ_CTRL_FULL_DUPLEX)

/* ---------------------------------------------------------------------------
 * STATUS register fields (read-only)
 * --------------------------------------------------------------------------- */
#define EMZ_STATUS_TX_ACTIVE     (1u << 0)
#define EMZ_STATUS_TX_FIFO_BUSY  (1u << 1)
#define EMZ_STATUS_MDIO_BUSY     (1u << 2)

/* ---------------------------------------------------------------------------
 * MDIO_CMD encoding:
 *   [4:0]=reg/devad  [9:5]=phy  [10]=write  [11]=go (W1, self-clear)
 *   [12]=clause-45 enable  [14:13]=clause-45 op
 * --------------------------------------------------------------------------- */
#define EMZ_MDIO_REG(r)   ((uint32_t)((r) & 0x1Fu))
#define EMZ_MDIO_DEVAD(d) EMZ_MDIO_REG(d)
#define EMZ_MDIO_PHY(p)   ((uint32_t)(((p) & 0x1Fu) << 5))
#define EMZ_MDIO_WRITE    (1u << 10)
#define EMZ_MDIO_GO       (1u << 11)
#define EMZ_MDIO_C45_EN   (1u << 12)
#define EMZ_MDIO_C45_OP_SHIFT 13
#define EMZ_MDIO_C45_OP_MASK  (0x3u << EMZ_MDIO_C45_OP_SHIFT)
#define EMZ_MDIO_C45_OP_ADDR     (0x0u << EMZ_MDIO_C45_OP_SHIFT)
#define EMZ_MDIO_C45_OP_WRITE    (0x1u << EMZ_MDIO_C45_OP_SHIFT)
#define EMZ_MDIO_C45_OP_READ_INC (0x2u << EMZ_MDIO_C45_OP_SHIFT)
#define EMZ_MDIO_C45_OP_READ     (0x3u << EMZ_MDIO_C45_OP_SHIFT)

/* ---------------------------------------------------------------------------
 * IRQ bits (shared by IRQ_EN and IRQ_STATUS; IRQ_STATUS is W1C)
 * --------------------------------------------------------------------------- */
#define EMZ_IRQ_TX_DONE   (1u << 0)
#define EMZ_IRQ_RX_FRAME  (1u << 1)
#define EMZ_IRQ_MDIO_DONE (1u << 2)

/* ---------------------------------------------------------------------------
 * PAUSE_CTRL register fields
 * --------------------------------------------------------------------------- */
#define EMZ_PAUSE_CTRL_TX_SEND (1u << 0)
#define EMZ_PAUSE_CTRL_RX_EN   (1u << 1)

/* ---------------------------------------------------------------------------
 * MMIO accessors. Override these macros if your platform needs barriers.
 * --------------------------------------------------------------------------- */
#ifndef emz_read32
#define emz_read32(addr)        (*(volatile uint32_t *)(addr))
#endif
#ifndef emz_write32
#define emz_write32(addr, val)  (*(volatile uint32_t *)(addr) = (uint32_t)(val))
#endif

/* ---------------------------------------------------------------------------
 * Driver context — just a base address. No internal state.
 * --------------------------------------------------------------------------- */
typedef struct {
    uintptr_t base;
} emz_t;

/* Initialise driver, set MAC address, leave TX/RX enabled at given speed.
 * mac is a 6-byte buffer (mac[0] = first byte on the wire).
 * speed: EMZ_SPEED_1G / _100M / _10M. Use _100M for the MII build.
 * Returns 0 on success, non-zero if the VERSION readback is wrong. */
int  emz_init(emz_t *d, uintptr_t base, const uint8_t mac[6], uint32_t speed);

/* Update CTRL register (read-modify-write). */
void emz_set_ctrl(emz_t *d, uint32_t set_bits, uint32_t clr_bits);

/* Set the station MAC address (mac[0] = first byte on the wire). */
void emz_set_mac(emz_t *d, const uint8_t mac[6]);

/* MDIO clause-22 read (returns 16-bit data, or 0xFFFF on timeout). */
uint16_t emz_mdio_read (emz_t *d, uint8_t phy, uint8_t reg);

/* MDIO clause-22 write (returns 0 on success, -1 on timeout). */
int      emz_mdio_write(emz_t *d, uint8_t phy, uint8_t reg, uint16_t val);

/* Acknowledge IRQ bits (W1C); pass any combination of EMZ_IRQ_*. */
static inline void emz_irq_ack(emz_t *d, uint32_t bits)
{
    emz_write32(d->base + EMZ_REG_IRQ_STATUS, bits);
}

/* Read VERSION register. axilite_regs.v reports 0x0001454D for v0.1/"EM". */
static inline uint32_t emz_version(emz_t *d)
{
    return emz_read32(d->base + EMZ_REG_VERSION);
}

#ifdef __cplusplus
}
#endif

#endif /* EMACZERO_H */
