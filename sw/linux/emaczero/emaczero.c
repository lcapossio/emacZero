// SPDX-License-Identifier: GPL-2.0-only OR Apache-2.0
/*
 * Linux netdev driver for the emacZero Ethernet MAC (eth_mac_sys).
 *
 * The MAC has no DMA engine of its own. Frames move between memory and its
 * AXI4-Stream ports through a dmaengine provider (on AMD parts the AXI DMA,
 * drivers/dma/xilinx/xilinx_dma.c): one "tx" (MEM_TO_DEV) and one "rx"
 * (DEV_TO_MEM) channel, one descriptor per frame. The provider calls back in
 * its own context; the callbacks only record the result and schedule NAPI,
 * which completes TX, delivers RX and refills the ring.
 *
 * Requirements on the shell around the MAC (see sw/linux/README.md):
 *   - TX: whole frames buffered before the MAC (a gap inside a frame is an
 *     underrun to eth_mac_tx).
 *   - RX: frames delivered with m_axis_terror dropped before the DMA, since
 *     terror arrives with the last byte, after the data is in memory.
 *
 * Copyright (c) 2026 Leonardo Capossio - bard0 design
 */

#include <linux/bitfield.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/of_net.h>
#include <linux/phy.h>
#include <linux/phylink.h>
#include <linux/platform_device.h>
#include <linux/rtnetlink.h>
#include <linux/skbuff.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>
#include <net/page_pool/helpers.h>

#define DRV_NAME "emaczero"

/* Registers (docs/registers.md) */
#define EMZ_VERSION		0x00
#define EMZ_CTRL		0x04
#define EMZ_STATUS		0x08
#define EMZ_MAC_LO		0x0c
#define EMZ_MAC_HI		0x10
#define EMZ_MDIO_CMD		0x14
#define EMZ_MDIO_WDATA		0x18
#define EMZ_MDIO_RDATA		0x1c
#define EMZ_IRQ_EN		0x20
#define EMZ_IRQ_STATUS		0x24
#define EMZ_MCAST_LO		0x44
#define EMZ_MCAST_HI		0x48
#define EMZ_RX_DROP		0x7c
#define EMZ_PAUSE_CTRL		0x84

#define EMZ_VERSION_ID		GENMASK(15, 0)
#define EMZ_VERSION_ID_VAL	0x454d	/* "EM" */
#define EMZ_VERSION_REV		GENMASK(31, 16)

#define EMZ_CTRL_TX_EN		BIT(0)
#define EMZ_CTRL_RX_EN		BIT(1)
#define EMZ_CTRL_PROMISC	BIT(2)
#define EMZ_CTRL_SPEED		GENMASK(4, 3)
#define EMZ_CTRL_SPEED_1000	0
#define EMZ_CTRL_SPEED_100	1
#define EMZ_CTRL_SPEED_10	2
#define EMZ_CTRL_FULL_DUPLEX	BIT(5)

#define EMZ_STATUS_MDIO_BUSY	BIT(2)

#define EMZ_MDIO_REG		GENMASK(4, 0)	/* C22 register or C45 DEVAD */
#define EMZ_MDIO_PHY		GENMASK(9, 5)
#define EMZ_MDIO_WRITE		BIT(10)
#define EMZ_MDIO_GO		BIT(11)
#define EMZ_MDIO_C45		BIT(12)
#define EMZ_MDIO_C45_OP		GENMASK(14, 13)
#define EMZ_MDIO_C45_ADDR	0
#define EMZ_MDIO_C45_WRITE	1
#define EMZ_MDIO_C45_READ	3

#define EMZ_IRQ_ALL		GENMASK(2, 0)

/*
 * RX buffers: room for the largest frame the MAC delivers with jumbo frames
 * off (1518 wire bytes with an 802.1Q tag, FCS stripped: 1518 bytes), rounded
 * to whole cache lines so cache maintenance never touches a neighbour.
 */
#define EMZ_RX_BUF_LEN		1536
/*
 * Each RX buffer is a fragment of a page-pool page: headroom for the stack,
 * the frame, then the skb's shared info. Cache-line headroom keeps the frame
 * aligned for the AXI DMA without its data realignment engine. Two buffers
 * share a 4 KB page, which halves what each frame charges to a socket.
 */
#define EMZ_RX_HEADROOM		NET_SKB_PAD
#define EMZ_RX_FRAG_LEN		roundup_pow_of_two(EMZ_RX_HEADROOM + EMZ_RX_BUF_LEN + \
						   SKB_DATA_ALIGN(sizeof(struct skb_shared_info)))
#define EMZ_MAX_TX_LEN		(VLAN_ETH_HLEN + ETH_DATA_LEN)
/*
 * TX goes through per-slot bounce buffers: the AXI DMA without its data
 * realignment engine needs buffers aligned to its memory bus width, and an
 * skb's Ethernet header usually starts 2 bytes off a word boundary.
 */
#define EMZ_TX_BUF_LEN		EMZ_RX_BUF_LEN

#define EMZ_TX_RING		64
/*
 * A larger RX ring tolerates more NAPI latency, but with xilinx_dma it lost
 * frames at 1G line rate behind the ZCU106 shell's 6 KB of RX buffering, and
 * 128 did not (measurements in sw/linux/README.md).
 */
#define EMZ_RX_RING		128
#define EMZ_RX_KICK		16	/* RX descriptors handed over at a time */
#define EMZ_TX_WAKE		(EMZ_TX_RING / 4)
#define EMZ_TX_TIMEOUT		(5 * HZ)
#define EMZ_WATCHDOG		HZ
#define EMZ_TX_STALL_TICKS	3	/* watchdog periods without a TX completion */
#define EMZ_NR_STATS		21
/* fold a counter group into the 64-bit totals once a counter passes this */
#define EMZ_STAT_FOLD		BIT(31)

#define EMZ_MDIO_TIMEOUT_US	10000

struct emz_tx_slot {
	void *buf;
	dma_addr_t dma;
	unsigned int len;
	int status;		/* 0, or -EIO when the DMA reported an error */
	bool done;		/* written by the DMA callback, read by NAPI */
};

struct emz_rx_slot {
	struct page *page;
	unsigned int offset;	/* of the fragment in the page */
	dma_addr_t dma;		/* of the frame, past the headroom */
	unsigned int len;
	int status;
	bool done;
};

struct emz_cb {
	struct emz_priv *priv;
	unsigned int idx;
};

struct emz_priv {
	struct net_device *ndev;
	struct device *dev;
	void __iomem *regs;

	struct dma_chan *tx_chan;
	struct dma_chan *rx_chan;
	struct device *tx_dma_dev;	/* the devices that master the bus */
	struct device *rx_dma_dev;

	struct napi_struct napi;

	struct emz_tx_slot tx[EMZ_TX_RING];
	struct emz_cb tx_cb[EMZ_TX_RING];
	unsigned int tx_head;		/* next slot to fill, xmit only */
	unsigned int tx_tail;		/* next slot to complete, NAPI only */

	struct emz_rx_slot rx[EMZ_RX_RING];
	struct emz_cb rx_cb[EMZ_RX_RING];
	struct page_pool *rx_pool;
	gfp_t rx_gfp;			/* zone the RX channel can reach */
	unsigned int rx_tail;		/* next slot to complete */

	spinlock_t ctrl_lock;		/* CTRL read-modify-write */
	bool has_mcast_hash;

	struct work_struct reset_work;	/* DMA error, TX timeout, RX stall */
	bool datapath_up;		/* channels held, rings allocated */
	bool reset_pending;		/* rebuild requested: submit nothing more */

	struct delayed_work watchdog;	/* RX and TX stall checks */
	struct delayed_work stats_work;	/* folds the MAC counters while bound */
	unsigned int rx_progress;	/* RX completions taken by NAPI */
	unsigned int wd_rx_progress;
	u64 wd_rx_drop;
	unsigned int wd_tx_tail;
	unsigned int wd_tx_stuck;

	struct mutex stats_lock;	/* stats_acc and the counter clears */
	u64 stats_acc[EMZ_NR_STATS];	/* counts folded out of the MAC */

	struct phylink *phylink;
	struct phylink_config phylink_config;
	struct mii_bus *mii;
};

static inline u32 emz_rd(struct emz_priv *priv, u32 reg)
{
	return readl(priv->regs + reg);
}

static inline void emz_wr(struct emz_priv *priv, u32 reg, u32 val)
{
	writel(val, priv->regs + reg);
}

static void emz_ctrl_update(struct emz_priv *priv, u32 clr, u32 set)
{
	unsigned long flags;
	u32 v;

	spin_lock_irqsave(&priv->ctrl_lock, flags);
	v = emz_rd(priv, EMZ_CTRL);
	v = (v & ~clr) | set;
	emz_wr(priv, EMZ_CTRL, v);
	spin_unlock_irqrestore(&priv->ctrl_lock, flags);
}

static void emz_write_mac(struct emz_priv *priv, const u8 *mac)
{
	emz_wr(priv, EMZ_MAC_LO, (u32)mac[2] << 24 | mac[3] << 16 | mac[4] << 8 | mac[5]);
	emz_wr(priv, EMZ_MAC_HI, mac[0] << 8 | mac[1]);
}

/* ------------------------------------------------------------------ MDIO */

static int emz_mdio_wait(struct emz_priv *priv)
{
	u32 v;

	return readl_poll_timeout(priv->regs + EMZ_STATUS, v, !(v & EMZ_STATUS_MDIO_BUSY),
				  10, EMZ_MDIO_TIMEOUT_US);
}

static int emz_mdio_cmd(struct emz_priv *priv, u32 cmd)
{
	int ret = emz_mdio_wait(priv);

	if (ret)
		return ret;
	emz_wr(priv, EMZ_MDIO_CMD, cmd | EMZ_MDIO_GO);
	return emz_mdio_wait(priv);
}

static int emz_mdio_read(struct mii_bus *bus, int addr, int regnum)
{
	struct emz_priv *priv = bus->priv;
	int ret;

	ret = emz_mdio_cmd(priv, FIELD_PREP(EMZ_MDIO_PHY, addr) | FIELD_PREP(EMZ_MDIO_REG, regnum));
	if (ret)
		return ret;
	return emz_rd(priv, EMZ_MDIO_RDATA) & 0xffff;
}

static int emz_mdio_write(struct mii_bus *bus, int addr, int regnum, u16 val)
{
	struct emz_priv *priv = bus->priv;
	int ret = emz_mdio_wait(priv);

	if (ret)
		return ret;
	emz_wr(priv, EMZ_MDIO_WDATA, val);
	return emz_mdio_cmd(priv, FIELD_PREP(EMZ_MDIO_PHY, addr) |
			    FIELD_PREP(EMZ_MDIO_REG, regnum) | EMZ_MDIO_WRITE);
}

static int emz_mdio_c45_addr(struct emz_priv *priv, int addr, int devad, int regnum)
{
	int ret = emz_mdio_wait(priv);

	if (ret)
		return ret;
	emz_wr(priv, EMZ_MDIO_WDATA, regnum);
	return emz_mdio_cmd(priv, FIELD_PREP(EMZ_MDIO_PHY, addr) |
			    FIELD_PREP(EMZ_MDIO_REG, devad) | EMZ_MDIO_C45 |
			    FIELD_PREP(EMZ_MDIO_C45_OP, EMZ_MDIO_C45_ADDR));
}

static int emz_mdio_read_c45(struct mii_bus *bus, int addr, int devad, int regnum)
{
	struct emz_priv *priv = bus->priv;
	int ret;

	ret = emz_mdio_c45_addr(priv, addr, devad, regnum);
	if (ret)
		return ret;
	ret = emz_mdio_cmd(priv, FIELD_PREP(EMZ_MDIO_PHY, addr) |
			   FIELD_PREP(EMZ_MDIO_REG, devad) | EMZ_MDIO_C45 |
			   FIELD_PREP(EMZ_MDIO_C45_OP, EMZ_MDIO_C45_READ));
	if (ret)
		return ret;
	return emz_rd(priv, EMZ_MDIO_RDATA) & 0xffff;
}

static int emz_mdio_write_c45(struct mii_bus *bus, int addr, int devad, int regnum, u16 val)
{
	struct emz_priv *priv = bus->priv;
	int ret;

	ret = emz_mdio_c45_addr(priv, addr, devad, regnum);
	if (ret)
		return ret;
	emz_wr(priv, EMZ_MDIO_WDATA, val);
	return emz_mdio_cmd(priv, FIELD_PREP(EMZ_MDIO_PHY, addr) |
			    FIELD_PREP(EMZ_MDIO_REG, devad) | EMZ_MDIO_C45 |
			    FIELD_PREP(EMZ_MDIO_C45_OP, EMZ_MDIO_C45_WRITE));
}

/* An "mdio" child node registers the MAC's MDIO master as a bus. */
static int emz_mdio_register(struct emz_priv *priv)
{
	struct device_node *np;
	struct mii_bus *bus;
	int ret;

	np = of_get_child_by_name(priv->dev->of_node, "mdio");
	if (!np)
		return 0;

	bus = devm_mdiobus_alloc(priv->dev);
	if (!bus) {
		of_node_put(np);
		return -ENOMEM;
	}
	bus->name = "emaczero mdio";
	snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(priv->dev));
	bus->parent = priv->dev;
	bus->priv = priv;
	bus->read = emz_mdio_read;
	bus->write = emz_mdio_write;
	bus->read_c45 = emz_mdio_read_c45;
	bus->write_c45 = emz_mdio_write_c45;

	ret = devm_of_mdiobus_register(priv->dev, bus, np);
	of_node_put(np);
	if (ret)
		return dev_err_probe(priv->dev, ret, "MDIO bus registration failed\n");
	priv->mii = bus;
	return 0;
}

/* --------------------------------------------------------- DMA callbacks */

/*
 * Stop feeding both channels and have the reset work rebuild them. After a
 * DMA error this matters: a submit to a channel with an error resets the
 * whole DMA core, under the other direction's feet. A channel can also halt
 * without any failed completion, which no flag here can catch in time; see
 * the known limits in sw/linux/README.md.
 */
static void emz_request_reset(struct emz_priv *priv)
{
	WRITE_ONCE(priv->reset_pending, true);
	schedule_work(&priv->reset_work);
}

/* The provider calls the completion callbacks from its tasklet. */
static void emz_tx_dma_done(void *param, const struct dmaengine_result *res)
{
	struct emz_cb *cb = param;
	struct emz_priv *priv = cb->priv;
	struct emz_tx_slot *slot = &priv->tx[cb->idx];
	bool failed = res->result != DMA_TRANS_NOERROR;

	/* once done is published NAPI may recycle the slot: decide from locals */
	slot->status = failed ? -EIO : 0;
	/* the gate before done, so whoever sees the failed slot sees the gate */
	if (failed)
		emz_request_reset(priv);
	/* status before done: pairs with the acquire in emz_tx_complete() */
	smp_store_release(&slot->done, true);
	napi_schedule(&priv->napi);
}

static void emz_rx_dma_done(void *param, const struct dmaengine_result *res)
{
	struct emz_cb *cb = param;
	struct emz_priv *priv = cb->priv;
	struct emz_rx_slot *slot = &priv->rx[cb->idx];
	bool failed = res->result != DMA_TRANS_NOERROR;

	/* bytes written = buffer length - residue; a short frame is dropped in NAPI */
	slot->len = EMZ_RX_BUF_LEN - min_t(u32, res->residue, EMZ_RX_BUF_LEN);
	slot->status = failed ? -EIO : 0;
	if (failed)
		emz_request_reset(priv);
	/* len, status and gate before done: pairs with the acquire in emz_rx_poll() */
	smp_store_release(&slot->done, true);
	napi_schedule(&priv->napi);
}

/* --------------------------------------------------------------- RX ring */

/* Hand slot idx's buffer to the RX channel. Caller issues pending work. */
static int emz_rx_submit(struct emz_priv *priv, unsigned int idx)
{
	struct emz_rx_slot *slot = &priv->rx[idx];
	struct dma_async_tx_descriptor *desc;
	dma_cookie_t cookie;

	/* the old completion is consumed whether or not this succeeds */
	slot->done = false;
	if (READ_ONCE(priv->reset_pending))
		return -EIO;
	desc = dmaengine_prep_slave_single(priv->rx_chan, slot->dma, EMZ_RX_BUF_LEN,
					   DMA_DEV_TO_MEM, DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc)
		return -ENOMEM;
	desc->callback_result = emz_rx_dma_done;
	desc->callback_param = &priv->rx_cb[idx];
	cookie = dmaengine_submit(desc);
	return dma_submit_error(cookie) ? -EIO : 0;
}

/* Give slot a buffer from the pool, mapped for the RX channel's device */
static int emz_rx_new(struct emz_priv *priv, struct emz_rx_slot *slot, gfp_t gfp)
{
	unsigned int offset;
	struct page *page;

	page = page_pool_alloc_frag(priv->rx_pool, &offset, EMZ_RX_FRAG_LEN,
				    gfp | __GFP_NOWARN | priv->rx_gfp);
	if (!page)
		return -ENOMEM;
	slot->page = page;
	slot->offset = offset;
	slot->dma = page_pool_get_dma_addr(page) + offset + EMZ_RX_HEADROOM;
	return 0;
}

static void emz_rx_free_all(struct emz_priv *priv)
{
	unsigned int i;

	if (!priv->rx_pool)
		return;
	for (i = 0; i < EMZ_RX_RING; i++) {
		struct emz_rx_slot *slot = &priv->rx[i];

		if (!slot->page)
			continue;
		page_pool_put_full_page(priv->rx_pool, slot->page, false);
		slot->page = NULL;
	}
	page_pool_destroy(priv->rx_pool);
	priv->rx_pool = NULL;
}

static int emz_rx_pool_create(struct emz_priv *priv)
{
	struct page_pool_params pp = {
		.flags = PP_FLAG_DMA_MAP | PP_FLAG_DMA_SYNC_DEV,
		.pool_size = EMZ_RX_RING / (PAGE_SIZE / EMZ_RX_FRAG_LEN),
		.nid = NUMA_NO_NODE,
		.dev = priv->rx_dma_dev,
		.napi = &priv->napi,
		.netdev = priv->ndev,
		.dma_dir = DMA_FROM_DEVICE,
		/* fragments: the whole page is synced back for the device */
		.max_len = PAGE_SIZE,
	};
	struct page_pool *pool;

	pool = page_pool_create(&pp);
	if (IS_ERR(pool))
		return PTR_ERR(pool);
	priv->rx_pool = pool;
	/*
	 * An AXI DMA with a 32-bit address width cannot reach all of memory on
	 * many boards: take pages it can reach, not ones bounced by SWIOTLB.
	 */
	priv->rx_gfp = dma_addressing_limited(priv->rx_dma_dev) ? GFP_DMA32 : 0;
	return 0;
}

static int emz_rx_poll(struct emz_priv *priv, int budget)
{
	struct net_device *ndev = priv->ndev;
	int done = 0, submitted = 0;

	while (done < budget) {
		unsigned int idx = priv->rx_tail;
		struct emz_rx_slot *slot = &priv->rx[idx];
		struct sk_buff *skb;
		unsigned int len, offset;
		struct page *page;

		/* pairs with the release in emz_rx_dma_done() */
		if (!smp_load_acquire(&slot->done))
			break;
		if (slot->status) {
			/* the channel halted: the reset work rebuilds the ring */
			DEV_STATS_INC(ndev, rx_errors);
			slot->done = false;
			break;
		}
		len = slot->len;
		page = slot->page;
		offset = slot->offset;

		if (len < ETH_HLEN) {
			DEV_STATS_INC(ndev, rx_length_errors);
		} else if (emz_rx_new(priv, slot, GFP_ATOMIC)) {
			/* no new buffer: drop this frame and post its buffer again */
			DEV_STATS_INC(ndev, rx_dropped);
		} else {
			page_pool_dma_sync_for_cpu(priv->rx_pool, page,
						   offset + EMZ_RX_HEADROOM, len);
			skb = napi_build_skb(page_address(page) + offset, EMZ_RX_FRAG_LEN);
			if (unlikely(!skb)) {
				page_pool_recycle_direct(priv->rx_pool, page);
				DEV_STATS_INC(ndev, rx_dropped);
			} else {
				skb_mark_for_recycle(skb);
				skb_reserve(skb, EMZ_RX_HEADROOM);
				skb_put(skb, len);
				skb->protocol = eth_type_trans(skb, ndev);
				dev_sw_netstats_rx_add(ndev, len);
				napi_gro_receive(&priv->napi, skb);
			}
		}
		WRITE_ONCE(priv->rx_progress, priv->rx_progress + 1);
		done++;

		/* stop at a slot that could not be posted again; the reset work rebuilds */
		if (emz_rx_submit(priv, idx)) {
			if (!READ_ONCE(priv->reset_pending))
				netdev_err(ndev, "RX descriptor submit failed\n");
			emz_request_reset(priv);
			break;
		}
		submitted++;
		priv->rx_tail = (idx + 1) % EMZ_RX_RING;
		/*
		 * The provider starts new descriptors on an idle channel only
		 * from issue_pending: hand them over in steps, so a channel that
		 * ran dry does not wait for the whole poll.
		 */
		if (submitted % EMZ_RX_KICK == 0)
			dma_async_issue_pending(priv->rx_chan);
	}

	if (submitted % EMZ_RX_KICK)
		dma_async_issue_pending(priv->rx_chan);
	return done;
}

/* --------------------------------------------------------------- TX ring */

static unsigned int emz_tx_free(struct emz_priv *priv)
{
	/*
	 * Acquire the tail: pairs with the release in emz_tx_complete(), so the
	 * reset gate, set before a failed slot was published, is seen after it.
	 */
	return EMZ_TX_RING - (READ_ONCE(priv->tx_head) - smp_load_acquire(&priv->tx_tail));
}

static void emz_tx_complete(struct emz_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	unsigned int tail = priv->tx_tail;
	/* slots below head are published: pairs with emz_start_xmit() */
	unsigned int head = smp_load_acquire(&priv->tx_head);
	unsigned int pkts = 0, bytes = 0;

	while (tail != head) {
		struct emz_tx_slot *slot = &priv->tx[tail % EMZ_TX_RING];

		/* pairs with the release in emz_tx_dma_done() */
		if (!smp_load_acquire(&slot->done))
			break;
		if (slot->status)
			DEV_STATS_INC(ndev, tx_errors);
		else
			dev_sw_netstats_tx_add(ndev, 1, slot->len);
		pkts++;
		bytes += slot->len;
		tail++;
	}
	if (!pkts)
		return;

	netdev_completed_queue(ndev, pkts, bytes);
	/* slots are read before xmit may refill them */
	smp_store_release(&priv->tx_tail, tail);

	/* pairs with the barrier in emz_start_xmit() after it stops the queue */
	smp_mb();
	if (netif_queue_stopped(ndev) && emz_tx_free(priv) >= EMZ_TX_WAKE)
		netif_wake_queue(ndev);
}

static netdev_tx_t emz_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct emz_priv *priv = netdev_priv(ndev);
	struct dma_async_tx_descriptor *desc;
	struct emz_tx_slot *slot;
	unsigned int head = priv->tx_head;
	unsigned int idx = head % EMZ_TX_RING;
	unsigned int len = skb->len;
	dma_cookie_t cookie;

	if (unlikely(!emz_tx_free(priv))) {
		netif_stop_queue(ndev);
		return NETDEV_TX_BUSY;
	}
	/* skb_copy_and_csum_dev() needs the checksum start in the linear part */
	if (unlikely(len > EMZ_TX_BUF_LEN || READ_ONCE(priv->reset_pending) ||
		     (skb->ip_summed == CHECKSUM_PARTIAL &&
		      skb_checksum_start_offset(skb) > skb_headlen(skb) &&
		      skb_checksum_help(skb)))) {
		DEV_STATS_INC(ndev, tx_dropped);
		dev_kfree_skb_any(skb);
		goto flush;
	}

	slot = &priv->tx[idx];
	/* the slot stays mapped: take it back for the CPU before writing it */
	dma_sync_single_for_cpu(priv->tx_dma_dev, slot->dma, len, DMA_TO_DEVICE);
	if (skb->ip_summed == CHECKSUM_PARTIAL)
		skb_copy_and_csum_dev(skb, slot->buf);
	else
		skb_copy_bits(skb, 0, slot->buf, len);
	dma_sync_single_for_device(priv->tx_dma_dev, slot->dma, len, DMA_TO_DEVICE);
	skb_tx_timestamp(skb);
	dev_consume_skb_any(skb);

	desc = dmaengine_prep_slave_single(priv->tx_chan, slot->dma, len, DMA_MEM_TO_DEV,
					   DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (unlikely(!desc)) {
		DEV_STATS_INC(ndev, tx_dropped);
		goto flush;
	}
	desc->callback_result = emz_tx_dma_done;
	desc->callback_param = &priv->tx_cb[idx];

	/*
	 * Publish the slot before submitting: once submitted, the provider may
	 * start it from its completion path, and NAPI must find it.
	 */
	slot->len = len;
	slot->status = 0;
	slot->done = false;
	netdev_sent_queue(ndev, len);
	/* slot fields before head: pairs with the acquire in emz_tx_complete() */
	smp_store_release(&priv->tx_head, head + 1);

	cookie = dmaengine_submit(desc);
	if (unlikely(dma_submit_error(cookie))) {
		/* complete the slot as failed so NAPI reclaims it, gate first */
		slot->status = -EIO;
		emz_request_reset(priv);
		/* pairs with the acquire in emz_tx_complete() */
		smp_store_release(&slot->done, true);
		napi_schedule(&priv->napi);
	}

	if (emz_tx_free(priv) == 0) {
		netif_stop_queue(ndev);
		dma_async_issue_pending(priv->tx_chan);
		/* pairs with the barrier in emz_tx_complete() */
		smp_mb();
		if (emz_tx_free(priv) >= EMZ_TX_WAKE)
			netif_start_queue(ndev);
		return NETDEV_TX_OK;
	}

flush:
	/* start what this batch submitted, including after a dropped last frame */
	if (!netdev_xmit_more())
		dma_async_issue_pending(priv->tx_chan);
	return NETDEV_TX_OK;
}

static int emz_tx_alloc_all(struct emz_priv *priv)
{
	unsigned int i;

	for (i = 0; i < EMZ_TX_RING; i++) {
		struct emz_tx_slot *slot = &priv->tx[i];

		/* within the DMA mask, so no bounce buffer behind this one */
		slot->buf = dma_alloc_noncoherent(priv->tx_dma_dev, EMZ_TX_BUF_LEN, &slot->dma,
						  DMA_TO_DEVICE, GFP_KERNEL);
		if (!slot->buf)
			return -ENOMEM;
	}
	return 0;
}

static void emz_tx_free_all(struct emz_priv *priv)
{
	unsigned int i;

	for (i = 0; i < EMZ_TX_RING; i++) {
		struct emz_tx_slot *slot = &priv->tx[i];

		if (!slot->buf)
			continue;
		dma_free_noncoherent(priv->tx_dma_dev, EMZ_TX_BUF_LEN, slot->buf, slot->dma,
				     DMA_TO_DEVICE);
		slot->buf = NULL;
	}
}

static int emz_poll(struct napi_struct *napi, int budget)
{
	struct emz_priv *priv = container_of(napi, struct emz_priv, napi);
	int done;

	emz_tx_complete(priv);
	done = emz_rx_poll(priv, budget);
	if (done < budget)
		napi_complete_done(napi, done);
	return done;
}

/* ------------------------------------------------------------ statistics */

/*
 * The MAC's own counters are 32 bits and saturate; a write to any counter of
 * a group clears the whole group. Keep 64-bit totals in software: once a
 * counter of a group passes 2^31, emz_stats_work() adds the group to the
 * totals and clears it. What a counter takes between that read and the clear
 * is lost from the totals.
 */
enum { EMZ_STAT_TX, EMZ_STAT_RX, EMZ_STAT_PAUSE, EMZ_STAT_GROUPS };

static const u16 emz_stat_clear[EMZ_STAT_GROUPS] = {
	[EMZ_STAT_TX]		= 0x28,
	[EMZ_STAT_RX]		= EMZ_RX_DROP,
	[EMZ_STAT_PAUSE]	= 0x8c,
};

static const struct {
	char name[ETH_GSTRING_LEN];
	u16 reg;
	u8 group;
} emz_hw_stats[EMZ_NR_STATS] = {
	{ "hw_tx_frames",		0x28, EMZ_STAT_TX },
	{ "hw_tx_bytes",		0x2c, EMZ_STAT_TX },
	{ "hw_rx_frames",		0x30, EMZ_STAT_RX },
	{ "hw_rx_bytes",		0x34, EMZ_STAT_RX },
	{ "hw_rx_errors",		0x38, EMZ_STAT_RX },
	{ "hw_rx_err_rx_er",		0x4c, EMZ_STAT_RX },
	{ "hw_rx_err_overflow",		0x50, EMZ_STAT_RX },
	{ "hw_rx_err_oversize",		0x54, EMZ_STAT_RX },
	{ "hw_rx_broadcast",		0x58, EMZ_STAT_RX },
	{ "hw_rx_multicast",		0x5c, EMZ_STAT_RX },
	{ "hw_rx_size_64",		0x60, EMZ_STAT_RX },
	{ "hw_rx_size_65_127",		0x64, EMZ_STAT_RX },
	{ "hw_rx_size_128_255",		0x68, EMZ_STAT_RX },
	{ "hw_rx_size_256_511",		0x6c, EMZ_STAT_RX },
	{ "hw_rx_size_512_1023",	0x70, EMZ_STAT_RX },
	{ "hw_rx_size_1024_1518",	0x74, EMZ_STAT_RX },
	{ "hw_rx_size_jumbo",		0x78, EMZ_STAT_RX },
	{ "hw_rx_drop_fifo_full",	EMZ_RX_DROP, EMZ_STAT_RX },
	{ "hw_rx_err_csum",		0x80, EMZ_STAT_RX },
	{ "hw_pause_rx",		0x8c, EMZ_STAT_PAUSE },
	{ "hw_pause_tx",		0x90, EMZ_STAT_PAUSE },
};

static void emz_stats_fold(struct emz_priv *priv)
{
	bool fold[EMZ_STAT_GROUPS] = { };
	unsigned long flags;
	unsigned int i, g;

	lockdep_assert_held(&priv->stats_lock);
	for (i = 0; i < EMZ_NR_STATS; i++)
		if (emz_rd(priv, emz_hw_stats[i].reg) >= EMZ_STAT_FOLD)
			fold[emz_hw_stats[i].group] = true;

	for (g = 0; g < EMZ_STAT_GROUPS; g++) {
		if (!fold[g])
			continue;
		/*
		 * A counter loses what it takes between its read and the clear.
		 * The table lists each group's busiest counters first: read the
		 * group backwards, so they are read just before the clear, and
		 * keep interrupts (and NAPI behind them) out of that window.
		 */
		local_irq_save(flags);
		for (i = EMZ_NR_STATS; i-- > 0; )
			if (emz_hw_stats[i].group == g)
				priv->stats_acc[i] += emz_rd(priv, emz_hw_stats[i].reg);
		emz_wr(priv, emz_stat_clear[g], 0);
		local_irq_restore(flags);
	}
}

/*
 * The MAC counts received frames even with RX disabled, so fold for as long
 * as the driver is bound, not only while the interface is up.
 */
static void emz_stats_work(struct work_struct *work)
{
	struct emz_priv *priv = container_of(to_delayed_work(work), struct emz_priv,
					     stats_work);

	mutex_lock(&priv->stats_lock);
	emz_stats_fold(priv);
	mutex_unlock(&priv->stats_lock);
	schedule_delayed_work(&priv->stats_work, EMZ_WATCHDOG);
}

static u64 emz_stat_total(struct emz_priv *priv, unsigned int i)
{
	lockdep_assert_held(&priv->stats_lock);
	return priv->stats_acc[i] + emz_rd(priv, emz_hw_stats[i].reg);
}

static u64 emz_rx_drop_total(struct emz_priv *priv)
{
	unsigned int i;

	for (i = 0; i < EMZ_NR_STATS; i++)
		if (emz_hw_stats[i].reg == EMZ_RX_DROP)
			return emz_stat_total(priv, i);
	return 0;
}

/* ------------------------------------------------------- datapath up/down */

static void emz_release_chans(struct emz_priv *priv)
{
	if (priv->rx_chan)
		dma_release_channel(priv->rx_chan);
	if (priv->tx_chan)
		dma_release_channel(priv->tx_chan);
	priv->rx_chan = NULL;
	priv->tx_chan = NULL;
}

/*
 * The channels are requested at every datapath start and released at every
 * stop, as xilinx_axienet does. Stopping a channel resets the whole AXI DMA
 * core, which clears the interrupt enables of the channel stopped first;
 * requesting both channels again turns both sets back on.
 */
static int emz_request_chans(struct emz_priv *priv)
{
	struct dma_chan *chan;

	chan = dma_request_chan(priv->dev, "tx");
	if (IS_ERR(chan))
		return PTR_ERR(chan);
	priv->tx_chan = chan;
	chan = dma_request_chan(priv->dev, "rx");
	if (IS_ERR(chan)) {
		emz_release_chans(priv);
		return PTR_ERR(chan);
	}
	priv->rx_chan = chan;
	priv->tx_dma_dev = dmaengine_get_dma_device(priv->tx_chan);
	priv->rx_dma_dev = dmaengine_get_dma_device(priv->rx_chan);
	return 0;
}

static void emz_datapath_down(struct emz_priv *priv)
{
	struct net_device *ndev = priv->ndev;

	if (!priv->datapath_up)
		return;
	priv->datapath_up = false;

	cancel_delayed_work_sync(&priv->watchdog);
	/* NAPI first: a running poll could wake the queue again */
	napi_disable(&priv->napi);
	netif_tx_disable(ndev);

	/*
	 * Drain TX into the MAC, then stop RX at the MAC. The TX channel halts
	 * only once its stream has taken the frame in progress, and xilinx_dma
	 * polls for that for minutes without sleeping, so make sure the MAC
	 * takes data.
	 */
	emz_ctrl_update(priv, 0, EMZ_CTRL_TX_EN);
	dmaengine_terminate_sync(priv->tx_chan);
	emz_ctrl_update(priv, EMZ_CTRL_TX_EN | EMZ_CTRL_RX_EN, 0);
	dmaengine_terminate_sync(priv->rx_chan);

	netdev_reset_queue(ndev);
	emz_tx_free_all(priv);
	emz_rx_free_all(priv);
	emz_release_chans(priv);
}

static int emz_datapath_up(struct emz_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	unsigned int i;
	int ret;

	memset(priv->tx, 0, sizeof(priv->tx));
	memset(priv->rx, 0, sizeof(priv->rx));
	for (i = 0; i < EMZ_TX_RING; i++)
		priv->tx_cb[i] = (struct emz_cb){ .priv = priv, .idx = i };
	for (i = 0; i < EMZ_RX_RING; i++)
		priv->rx_cb[i] = (struct emz_cb){ .priv = priv, .idx = i };
	priv->tx_head = 0;
	priv->tx_tail = 0;
	priv->rx_tail = 0;
	priv->reset_pending = false;

	ret = emz_request_chans(priv);
	if (ret)
		return ret;
	ret = emz_tx_alloc_all(priv);
	if (ret)
		goto err;
	ret = emz_rx_pool_create(priv);
	if (ret)
		goto err;
	for (i = 0; i < EMZ_RX_RING; i++) {
		ret = emz_rx_new(priv, &priv->rx[i], GFP_KERNEL);
		if (ret)
			goto err;
	}

	netdev_reset_queue(ndev);
	/* before the first completion can call napi_schedule() */
	napi_enable(&priv->napi);

	for (i = 0; i < EMZ_RX_RING; i++) {
		ret = emz_rx_submit(priv, i);
		if (ret) {
			napi_disable(&priv->napi);
			goto err;
		}
	}
	dma_async_issue_pending(priv->rx_chan);
	emz_ctrl_update(priv, 0, EMZ_CTRL_TX_EN | EMZ_CTRL_RX_EN);
	priv->datapath_up = true;
	netif_wake_queue(ndev);

	mutex_lock(&priv->stats_lock);
	priv->wd_rx_drop = emz_rx_drop_total(priv);
	mutex_unlock(&priv->stats_lock);
	priv->wd_rx_progress = READ_ONCE(priv->rx_progress);
	priv->wd_tx_tail = 0;
	priv->wd_tx_stuck = 0;
	schedule_delayed_work(&priv->watchdog, EMZ_WATCHDOG);
	return 0;

err:
	dmaengine_terminate_sync(priv->rx_chan);
	emz_tx_free_all(priv);
	emz_rx_free_all(priv);
	emz_release_chans(priv);
	return ret;
}

/* Rebuild both directions: after a DMA error, a TX timeout or an RX stall. */
static void emz_reset_work(struct work_struct *work)
{
	struct emz_priv *priv = container_of(work, struct emz_priv, reset_work);
	struct net_device *ndev = priv->ndev;
	int ret;

	rtnl_lock();
	/*
	 * A request made while the last rebuild ran queues the work again; the
	 * rebuild cleared the gate, so that run finds nothing to do.
	 */
	if (netif_running(ndev) && priv->datapath_up && READ_ONCE(priv->reset_pending)) {
		netdev_warn(ndev, "restarting the DMA datapath\n");
		emz_datapath_down(priv);
		ret = emz_datapath_up(priv);
		if (ret) {
			/* no datapath: take the interface down rather than leave it up and dead */
			netdev_err(ndev, "datapath restart failed (%d), closing the interface\n",
				   ret);
			dev_close(ndev);
		}
	}
	rtnl_unlock();
}

/*
 * The provider reports a channel error only through a completion, and a
 * channel can halt with none. Every second: for RX, frames the MAC dropped
 * for lack of room while NAPI took nothing mean the RX channel stopped; for
 * TX, frames in flight with no completion for EMZ_TX_STALL_TICKS periods mean
 * the TX channel stopped (the stack's TX timeout only covers a stopped
 * queue). With the carrier off the TX check waits: the frames may only be
 * held up.
 */
static void emz_watchdog(struct work_struct *work)
{
	struct emz_priv *priv = container_of(to_delayed_work(work), struct emz_priv, watchdog);
	struct net_device *ndev = priv->ndev;
	unsigned int progress = READ_ONCE(priv->rx_progress);
	/* pairs with the release in emz_tx_complete() */
	unsigned int tx_tail = smp_load_acquire(&priv->tx_tail);
	bool tx_busy = READ_ONCE(priv->tx_head) != tx_tail;
	u64 drop;

	mutex_lock(&priv->stats_lock);
	drop = emz_rx_drop_total(priv);
	mutex_unlock(&priv->stats_lock);

	if (drop != priv->wd_rx_drop && progress == priv->wd_rx_progress) {
		netdev_warn(ndev, "RX DMA stalled (MAC dropped %llu frames)\n",
			    drop - priv->wd_rx_drop);
		emz_request_reset(priv);
		return;
	}
	priv->wd_rx_drop = drop;
	priv->wd_rx_progress = progress;

	if (tx_busy && tx_tail == priv->wd_tx_tail && netif_carrier_ok(ndev)) {
		if (++priv->wd_tx_stuck >= EMZ_TX_STALL_TICKS) {
			netdev_warn(ndev, "TX DMA stalled, %u frames in flight\n",
				    EMZ_TX_RING - emz_tx_free(priv));
			emz_request_reset(priv);
			return;
		}
	} else {
		priv->wd_tx_stuck = 0;
	}
	priv->wd_tx_tail = tx_tail;

	schedule_delayed_work(&priv->watchdog, EMZ_WATCHDOG);
}

/* --------------------------------------------------------- netdev ops */

static int emz_open(struct net_device *ndev)
{
	struct emz_priv *priv = netdev_priv(ndev);
	int ret;

	ret = phylink_of_phy_connect(priv->phylink, priv->dev->of_node, 0);
	if (ret) {
		netdev_err(ndev, "could not attach to the PHY: %d\n", ret);
		return ret;
	}

	ret = emz_datapath_up(priv);
	if (ret) {
		phylink_disconnect_phy(priv->phylink);
		return ret;
	}
	phylink_start(priv->phylink);
	return 0;
}

static int emz_stop(struct net_device *ndev)
{
	struct emz_priv *priv = netdev_priv(ndev);

	phylink_stop(priv->phylink);
	phylink_disconnect_phy(priv->phylink);
	emz_datapath_down(priv);
	return 0;
}

static void emz_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct emz_priv *priv = netdev_priv(ndev);

	netdev_warn(ndev, "TX timeout, %u frames in flight\n", EMZ_TX_RING - emz_tx_free(priv));
	emz_request_reset(priv);
}

static int emz_set_mac_address(struct net_device *ndev, void *p)
{
	struct emz_priv *priv = netdev_priv(ndev);
	int ret;

	ret = eth_mac_addr(ndev, p);
	if (ret)
		return ret;
	emz_write_mac(priv, ndev->dev_addr);
	return 0;
}

/*
 * The RX filter's hash: XOR of the eight 6-bit slices of the destination
 * address, first byte in bits 47:40 (rtl/eth_mac_rx.v).
 */
static unsigned int emz_mcast_hash(const u8 *addr)
{
	u64 v = 0;
	unsigned int h = 0;
	int i;

	for (i = 0; i < ETH_ALEN; i++)
		v = (v << 8) | addr[i];
	for (i = 0; i < 8; i++)
		h ^= (v >> (6 * i)) & 0x3f;
	return h;
}

static void emz_set_rx_mode(struct net_device *ndev)
{
	struct emz_priv *priv = netdev_priv(ndev);
	struct netdev_hw_addr *ha;
	bool promisc = ndev->flags & IFF_PROMISC;
	u64 hash = 0;

	if (ndev->flags & IFF_ALLMULTI) {
		hash = ~0ULL;
	} else {
		netdev_for_each_mc_addr(ha, ndev)
			hash |= BIT_ULL(emz_mcast_hash(ha->addr));
	}

	if (priv->has_mcast_hash) {
		emz_wr(priv, EMZ_MCAST_LO, lower_32_bits(hash));
		emz_wr(priv, EMZ_MCAST_HI, upper_32_bits(hash));
	} else if (hash) {
		/* no hash filter in this build: multicast needs the filter off */
		promisc = true;
	}
	emz_ctrl_update(priv, EMZ_CTRL_PROMISC, promisc ? EMZ_CTRL_PROMISC : 0);
}

static int emz_ioctl(struct net_device *ndev, struct ifreq *rq, int cmd)
{
	struct emz_priv *priv = netdev_priv(ndev);

	return phylink_mii_ioctl(priv->phylink, rq, cmd);
}

static const struct net_device_ops emz_netdev_ops = {
	.ndo_open		= emz_open,
	.ndo_stop		= emz_stop,
	.ndo_start_xmit		= emz_start_xmit,
	.ndo_tx_timeout		= emz_tx_timeout,
	.ndo_set_mac_address	= emz_set_mac_address,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_set_rx_mode	= emz_set_rx_mode,
	.ndo_eth_ioctl		= emz_ioctl,
	.ndo_get_stats64	= dev_get_tstats64,
};

/* --------------------------------------------------------- ethtool */

static void emz_get_drvinfo(struct net_device *ndev, struct ethtool_drvinfo *info)
{
	struct emz_priv *priv = netdev_priv(ndev);

	strscpy(info->driver, DRV_NAME, sizeof(info->driver));
	strscpy(info->bus_info, dev_name(priv->dev), sizeof(info->bus_info));
	snprintf(info->fw_version, sizeof(info->fw_version), "rev %lu",
		 FIELD_GET(EMZ_VERSION_REV, emz_rd(priv, EMZ_VERSION)));
}

static int emz_get_sset_count(struct net_device *ndev, int sset)
{
	return sset == ETH_SS_STATS ? EMZ_NR_STATS : -EOPNOTSUPP;
}

static void emz_get_strings(struct net_device *ndev, u32 sset, u8 *data)
{
	unsigned int i;

	if (sset != ETH_SS_STATS)
		return;
	for (i = 0; i < ARRAY_SIZE(emz_hw_stats); i++)
		ethtool_puts(&data, emz_hw_stats[i].name);
}

static void emz_get_ethtool_stats(struct net_device *ndev, struct ethtool_stats *stats, u64 *data)
{
	struct emz_priv *priv = netdev_priv(ndev);
	unsigned int i;

	mutex_lock(&priv->stats_lock);
	for (i = 0; i < EMZ_NR_STATS; i++)
		data[i] = emz_stat_total(priv, i);
	mutex_unlock(&priv->stats_lock);
}

static int emz_get_link_ksettings(struct net_device *ndev, struct ethtool_link_ksettings *cmd)
{
	struct emz_priv *priv = netdev_priv(ndev);

	return phylink_ethtool_ksettings_get(priv->phylink, cmd);
}

static int emz_set_link_ksettings(struct net_device *ndev, const struct ethtool_link_ksettings *cmd)
{
	struct emz_priv *priv = netdev_priv(ndev);

	return phylink_ethtool_ksettings_set(priv->phylink, cmd);
}

static int emz_nway_reset(struct net_device *ndev)
{
	struct emz_priv *priv = netdev_priv(ndev);

	return phylink_ethtool_nway_reset(priv->phylink);
}

static const struct ethtool_ops emz_ethtool_ops = {
	.get_drvinfo		= emz_get_drvinfo,
	.get_link		= ethtool_op_get_link,
	.get_sset_count		= emz_get_sset_count,
	.get_strings		= emz_get_strings,
	.get_ethtool_stats	= emz_get_ethtool_stats,
	.get_link_ksettings	= emz_get_link_ksettings,
	.set_link_ksettings	= emz_set_link_ksettings,
	.nway_reset		= emz_nway_reset,
};

/* --------------------------------------------------------- phylink */

static struct emz_priv *to_emz(struct phylink_config *config)
{
	return netdev_priv(to_net_dev(config->dev));
}

static void emz_mac_config(struct phylink_config *config, unsigned int mode,
			   const struct phylink_link_state *state)
{
	/* nothing to set up per interface mode: the build fixes it */
}

static void emz_mac_link_down(struct phylink_config *config, unsigned int mode,
			      phy_interface_t interface)
{
}

static void emz_mac_link_up(struct phylink_config *config, struct phy_device *phy,
			    unsigned int mode, phy_interface_t interface, int speed,
			    int duplex, bool tx_pause, bool rx_pause)
{
	struct emz_priv *priv = to_emz(config);
	u32 code;

	switch (speed) {
	case SPEED_10:
		code = EMZ_CTRL_SPEED_10;
		break;
	case SPEED_100:
		code = EMZ_CTRL_SPEED_100;
		break;
	default:
		code = EMZ_CTRL_SPEED_1000;
		break;
	}
	/* GMII builds ignore the speed code; MII / RGMII builds pace by it */
	emz_ctrl_update(priv, EMZ_CTRL_SPEED, FIELD_PREP(EMZ_CTRL_SPEED, code));
}

static const struct phylink_mac_ops emz_phylink_ops = {
	.mac_config	= emz_mac_config,
	.mac_link_down	= emz_mac_link_down,
	.mac_link_up	= emz_mac_link_up,
};

/* --------------------------------------------------------- probe */

static void emz_phylink_destroy(void *data)
{
	phylink_destroy(data);
}

static void emz_cancel_stats(void *data)
{
	struct emz_priv *priv = data;

	cancel_delayed_work_sync(&priv->stats_work);
}

static void emz_cancel_reset(void *data)
{
	struct emz_priv *priv = data;

	cancel_work_sync(&priv->reset_work);
}

static int emz_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct emz_priv *priv;
	const char *managed;
	phy_interface_t iface;
	unsigned int i;
	u32 ver, max_speed;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*priv));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	priv = netdev_priv(ndev);
	priv->ndev = ndev;
	priv->dev = dev;
	spin_lock_init(&priv->ctrl_lock);
	mutex_init(&priv->stats_lock);
	INIT_WORK(&priv->reset_work, emz_reset_work);
	INIT_DELAYED_WORK(&priv->watchdog, emz_watchdog);
	INIT_DELAYED_WORK(&priv->stats_work, emz_stats_work);

	priv->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(priv->regs))
		return PTR_ERR(priv->regs);

	ver = emz_rd(priv, EMZ_VERSION);
	if (FIELD_GET(EMZ_VERSION_ID, ver) != EMZ_VERSION_ID_VAL)
		return dev_err_probe(dev, -ENODEV, "VERSION reads 0x%08x, not an emacZero\n", ver);

	/* MAC off, interrupts off (packets complete through the DMA channels) */
	emz_wr(priv, EMZ_CTRL, EMZ_CTRL_FULL_DUPLEX);
	emz_wr(priv, EMZ_IRQ_EN, 0);
	emz_wr(priv, EMZ_IRQ_STATUS, EMZ_IRQ_ALL);
	/*
	 * The driver does not set up flow control (phylink resolves it off):
	 * ignore PAUSE frames, or they could hold TX and trip the TX watchdog.
	 */
	emz_wr(priv, EMZ_PAUSE_CTRL, 0);
	/* the MAC counters count from here; a reload starts them again */
	for (i = 0; i < EMZ_STAT_GROUPS; i++)
		emz_wr(priv, emz_stat_clear[i], 0);
	/* devm actions run in reverse: this one before the registers go */
	schedule_delayed_work(&priv->stats_work, EMZ_WATCHDOG);
	ret = devm_add_action_or_reset(dev, emz_cancel_stats, priv);
	if (ret)
		return ret;

	/* the multicast hash registers read 0 when the build leaves them out */
	emz_wr(priv, EMZ_MCAST_LO, 1);
	priv->has_mcast_hash = emz_rd(priv, EMZ_MCAST_LO) == 1;
	emz_wr(priv, EMZ_MCAST_LO, 0);

	/* the channels are taken at ifup; here only defer until they exist */
	ret = emz_request_chans(priv);
	if (ret)
		return dev_err_probe(dev, ret, "no tx/rx DMA channels\n");
	emz_release_chans(priv);

	ret = emz_mdio_register(priv);
	if (ret)
		return ret;

	ret = of_get_phy_mode(dev->of_node, &iface);
	if (ret)
		return dev_err_probe(dev, ret, "missing or bad phy-mode\n");
	/* the driver has no PCS to resolve in-band status with */
	if (!of_property_read_string(dev->of_node, "managed", &managed) &&
	    !strcmp(managed, "in-band-status"))
		return dev_err_probe(dev, -EINVAL, "in-band-status is not supported\n");

	priv->phylink_config.dev = &ndev->dev;
	priv->phylink_config.type = PHYLINK_NETDEV;
	/*
	 * The build fixes the interface: MII runs at 10/100, GMII only at 1000
	 * (also behind a PCS for SGMII or 1000BASE-X), RGMII at all three. Full
	 * duplex only: the MAC has no CSMA/CD.
	 */
	switch (iface) {
	case PHY_INTERFACE_MODE_MII:
		priv->phylink_config.mac_capabilities = MAC_10FD | MAC_100FD;
		__set_bit(iface, priv->phylink_config.supported_interfaces);
		break;
	case PHY_INTERFACE_MODE_GMII:
	case PHY_INTERFACE_MODE_SGMII:
	case PHY_INTERFACE_MODE_1000BASEX:
		priv->phylink_config.mac_capabilities = MAC_1000FD;
		__set_bit(iface, priv->phylink_config.supported_interfaces);
		break;
	default:
		if (!phy_interface_mode_is_rgmii(iface))
			return dev_err_probe(dev, -EINVAL, "phy-mode %s is not supported\n",
					     phy_modes(iface));
		priv->phylink_config.mac_capabilities = MAC_10FD | MAC_100FD | MAC_1000FD;
		phy_interface_set_rgmii(priv->phylink_config.supported_interfaces);
		break;
	}

	/* a build with fewer speeds (RGMII_SPEEDS "10_100") sets max-speed */
	if (!of_property_read_u32(dev->of_node, "max-speed", &max_speed)) {
		if (max_speed < SPEED_1000)
			priv->phylink_config.mac_capabilities &= ~MAC_1000FD;
		if (max_speed < SPEED_100)
			priv->phylink_config.mac_capabilities &= ~MAC_100FD;
		if (!priv->phylink_config.mac_capabilities)
			return dev_err_probe(dev, -EINVAL, "no speed left under max-speed %u\n",
					     max_speed);
	}

	priv->phylink = phylink_create(&priv->phylink_config, dev_fwnode(dev), iface,
				       &emz_phylink_ops);
	if (IS_ERR(priv->phylink))
		return dev_err_probe(dev, PTR_ERR(priv->phylink), "phylink setup failed\n");
	ret = devm_add_action_or_reset(dev, emz_phylink_destroy, priv->phylink);
	if (ret)
		return ret;

	ret = of_get_ethdev_address(dev->of_node, ndev);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (ret) {
		eth_hw_addr_random(ndev);
		dev_info(dev, "no MAC address in the device tree, using %pM\n", ndev->dev_addr);
	}
	emz_write_mac(priv, ndev->dev_addr);

	ndev->netdev_ops = &emz_netdev_ops;
	ndev->ethtool_ops = &emz_ethtool_ops;
	ndev->watchdog_timeo = EMZ_TX_TIMEOUT;
	ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS;
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = ETH_DATA_LEN;
	/*
	 * Every frame is copied into a bounce buffer, so take fragments and
	 * fill in the checksum during that copy: the stack then skips its own
	 * linearising copy and checksum pass.
	 */
	ndev->hw_features = NETIF_F_SG | NETIF_F_HW_CSUM;
	ndev->features = ndev->hw_features;
	netif_napi_add(ndev, &priv->napi, emz_poll);

	/* devm actions run in reverse: this one after the netdev is unregistered */
	ret = devm_add_action_or_reset(dev, emz_cancel_reset, priv);
	if (ret)
		return ret;

	ret = devm_register_netdev(dev, ndev);
	if (ret)
		return dev_err_probe(dev, ret, "netdev registration failed\n");

	netdev_info(ndev, "emacZero rev %lu at %pa, %s, multicast hash %s\n",
		    FIELD_GET(EMZ_VERSION_REV, ver), &pdev->resource[0].start,
		    phy_modes(iface), priv->has_mcast_hash ? "yes" : "no");
	return 0;
}

static const struct of_device_id emz_of_match[] = {
	{ .compatible = "bard0,emaczero" },
	{ }
};
MODULE_DEVICE_TABLE(of, emz_of_match);

static struct platform_driver emz_driver = {
	.probe = emz_probe,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = emz_of_match,
	},
};
module_platform_driver(emz_driver);

MODULE_AUTHOR("Leonardo Capossio <hello@bard0.com>");
MODULE_DESCRIPTION("emacZero Ethernet MAC driver");
MODULE_LICENSE("GPL");
