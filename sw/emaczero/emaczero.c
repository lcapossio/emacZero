/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Leonardo Capossio - bard0 design
 *
 * emaczero.c — bare-metal driver for eth_mac_sys.
 * No malloc, no printf, no OS calls. Tested against axilite_regs.v.
 */

#include "emaczero.h"

/* MDIO completion is signalled by mdio_busy clearing. The MAC clocks MDC at
 * sys_clk/64 (default), so a 16-bit clause-22 transaction takes ~64 * 32 =
 * 2048 sys_clk cycles. We poll up to MDIO_POLL_LIMIT loop iterations. */
#define EMZ_MDIO_POLL_LIMIT 100000u

static int emz_mdio_wait(emz_t *d)
{
    for (uint32_t i = 0; i < EMZ_MDIO_POLL_LIMIT; ++i) {
        if (!(emz_read32(d->base + EMZ_REG_STATUS) & EMZ_STATUS_MDIO_BUSY))
            return 0;
    }
    return -1;
}

void emz_set_mac(emz_t *d, const uint8_t mac[6])
{
    uint32_t lo = (uint32_t)mac[2] << 24
                | (uint32_t)mac[3] << 16
                | (uint32_t)mac[4] <<  8
                | (uint32_t)mac[5];
    uint32_t hi = (uint32_t)mac[0] <<  8
                | (uint32_t)mac[1];
    emz_write32(d->base + EMZ_REG_MAC_LO, lo);
    emz_write32(d->base + EMZ_REG_MAC_HI, hi);
}

void emz_set_ctrl(emz_t *d, uint32_t set_bits, uint32_t clr_bits)
{
    uint32_t v = emz_read32(d->base + EMZ_REG_CTRL);
    v = (v & ~clr_bits) | set_bits;
    emz_write32(d->base + EMZ_REG_CTRL, v);
}

uint16_t emz_mdio_read(emz_t *d, uint8_t phy, uint8_t reg)
{
    if (emz_mdio_wait(d))
        return 0xFFFFu;
    emz_write32(d->base + EMZ_REG_MDIO_CMD,
                EMZ_MDIO_GO | EMZ_MDIO_PHY(phy) | EMZ_MDIO_REG(reg));
    if (emz_mdio_wait(d))
        return 0xFFFFu;
    return (uint16_t)(emz_read32(d->base + EMZ_REG_MDIO_RDATA) & 0xFFFFu);
}

int emz_mdio_write(emz_t *d, uint8_t phy, uint8_t reg, uint16_t val)
{
    if (emz_mdio_wait(d))
        return -1;
    emz_write32(d->base + EMZ_REG_MDIO_WDATA, val);
    emz_write32(d->base + EMZ_REG_MDIO_CMD,
                EMZ_MDIO_GO | EMZ_MDIO_WRITE
                | EMZ_MDIO_PHY(phy) | EMZ_MDIO_REG(reg));
    return emz_mdio_wait(d);
}

int emz_init(emz_t *d, uintptr_t base, const uint8_t mac[6], uint32_t speed)
{
    d->base = base;

    if (emz_read32(base + EMZ_REG_VERSION) != EMZ_VERSION_VALUE)
        return -1;

    emz_set_mac(d, mac);

    uint32_t ctrl = EMZ_CTRL_TX_EN | EMZ_CTRL_RX_EN | EMZ_CTRL_FULL_DUPLEX
                  | ((speed << EMZ_CTRL_SPEED_SHIFT) & EMZ_CTRL_SPEED_MASK);
    emz_write32(base + EMZ_REG_CTRL, ctrl);

    /* Clear any latched IRQ state and disable IRQs by default. */
    emz_write32(base + EMZ_REG_IRQ_EN,     0);
    emz_write32(base + EMZ_REG_IRQ_STATUS, EMZ_IRQ_TX_DONE
                                          | EMZ_IRQ_RX_FRAME
                                          | EMZ_IRQ_MDIO_DONE);
    return 0;
}
