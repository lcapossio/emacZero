# emaczero Linux driver benchmark, 2026-10-25

ZCU106 (xczu7ev, 4x Cortex-A53 at 1.2 GHz), Linux 6.12.60 (linux-xlnx, PREEMPT_NONE, HZ=250, CONFIG_PAGE_POOL=y), emacz_zephyr zcu106_r5 block design: emacZero rev 1 behind an AXI DMA 7.1 (SG, 32-bit memory side, no DRE) at 150 MHz, non-coherent. Link: 1000BASE-X over fibre to a PC SFP port. Driver defaults: RX ring 128 (page pool, two buffers per page), TX ring 64, SG and TX checksum on (summed during the bounce copy, zero sent as 0xffff), threaded NAPI (the driver's default), no RPS, DMA interrupt affinity left at the default. The board's iperf3 server pinned to CPU2. Host: Windows 11 PC, iperf3 in WSL2.

Board: 6.12.60, driver: emaczero, version: 6.12.60; counters read over the serial console

Host: iperf 3.16 (cJSON 1.7.15); 10 s per test unless stated

## TCP, board receives

- board receives: 941 Mb/s, 0 retransmits
- TX: MAC 49,217, interface 49,217
- RX: MAC 836,696 - bad 0 = 836,696, interface 836,696
- MAC RX overflow 0, dropped for FIFO full 0; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory -10,828 kB

## TCP, board sends

- board sends: 962 Mb/s, 0 retransmits
- TX: MAC 831,787, interface 831,787
- RX: MAC 133,433 - bad 0 = 133,433, interface 133,433
- MAC RX overflow 0, dropped for FIFO full 0; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory +4,032 kB

## UDP 1472-byte, 950Mb/s offered, board receives

- board receives: 930 Mb/s received (950 sent); iperf3: 806,669 sent, receiver sequence to 806,669, 0 gaps
- TX: MAC 14, interface 14
- RX: MAC 806,688 - bad 0 = 806,688, interface 806,688
- MAC RX overflow 0, dropped for FIFO full 0; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory -2,156 kB

## UDP 1472-byte, 950Mb/s offered, board sends

- board sends: 858 Mb/s received (836 sent); iperf3: 729,954 sent, receiver sequence to 729,814, 1,530 gaps
- TX: MAC 729,969, interface 729,969
- RX: MAC 21 - bad 0 = 21, interface 21
- MAC RX overflow 0, dropped for FIFO full 0; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory +3,868 kB

## TCP, both directions, 10 s

- board receives: 835 Mb/s, 16 retransmits
- board sends: 929 Mb/s, 0 retransmits
- TX: MAC 860,943, interface 860,943
- RX: MAC 869,624 - bad 12 = 869,612, interface 869,612
- MAC RX overflow 12, dropped for FIFO full 4; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory -2,568 kB

## TCP, both directions, 300 s

- board receives: 799 Mb/s, 405 retransmits
- board sends: 931 Mb/s, 87 retransmits
- TX: MAC 25,974,754, interface 25,974,754
- RX: MAC 25,931,298 - bad 155 = 25,931,143, interface 25,931,144 (MAC -1)
- MAC RX overflow 155, dropped for FIFO full 312; interface RX dropped 0, errors 0, length errors 0
- no kernel messages
- BQL inflight after: 0, free memory +272 kB

Tests: 5 agree, 1 differ, 0 invalid. A fold of the MAC counters into the driver's 64-bit totals loses what a counter takes during its read and clear (sw/linux/README.md, Statistics); a larger or persistent difference has another cause.
