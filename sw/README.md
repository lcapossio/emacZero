# emacZero — bare-metal driver

Minimal C driver for `eth_mac_sys` exposed over AXI4-Lite. No OS, no malloc.

| File | Purpose |
|------|---------|
| [emaczero/emaczero.h](emaczero/emaczero.h) | Register offsets, bit fields, prototypes |
| [emaczero/emaczero.c](emaczero/emaczero.c) | `emz_init`, `emz_mdio_read/write`, `emz_set_mac`, `emz_set_ctrl` |

## Wiring

The driver assumes the AXI4-Lite slave is mapped to a fixed base address in
the host CPU's address space. Override the MMIO accessors if your platform
needs explicit barriers or a different access width:

```c
#define emz_read32(a)     my_mmio_rd32(a)
#define emz_write32(a,v)  my_mmio_wr32(a,v)
#include "emaczero.h"
```

## Quickstart

```c
#include "emaczero.h"

#define ETH_MAC_BASE 0x60000000u   /* wherever you mapped s_axi */

int main(void) {
    emz_t mac;
    uint8_t addr[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};

    if (emz_init(&mac, ETH_MAC_BASE, addr, EMZ_SPEED_100M) != 0)
        return -1;  /* VERSION mismatch — base address wrong? */

    /* Read PHY ID register 2 (clause 22) */
    uint16_t phy_id = emz_mdio_read(&mac, /*phy=*/0x01, /*reg=*/2);

    /* Toggle promiscuous mode on */
    emz_set_ctrl(&mac, EMZ_CTRL_PROMISC, 0);

    /* Enable RX-frame interrupt */
    emz_write32(mac.base + EMZ_REG_IRQ_EN, EMZ_IRQ_RX_FRAME);

    /* ... your TX/RX loop drives s_axis_* / m_axis_* on the AXI-Stream
     *     interfaces; the driver here only owns the CSR side. */
    (void)phy_id;
    return 0;
}
```

## Building into your project

It's two files; drop `emaczero.[ch]` into your firmware tree and add
`emaczero.c` to your build. C99 or later, no external dependencies.
