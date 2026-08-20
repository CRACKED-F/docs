# Phase 14 — Networking

**Goal:** talk to other machines. You will write a **NIC driver**, then build
**ARP**, **IPv4**, **ICMP**, **UDP**, and **TCP** on top of it, and expose it all
through a **BSD sockets** API so user programs can use it.

At the end of this phase your OS answers a ping from your laptop and serves an HTTP
response over TCP.

> Prerequisite: [[Phase 11 - Overview|Phase 11]] (PCI, to find the NIC),
> [[Phase 13 - Overview|Phase 13]] (file descriptors — sockets are fds),
> [[Phase 12 - Overview|Phase 12]] (the network stack is concurrent by nature).

---

## Why this phase exists

"Server-grade" was the chosen scope in [[15 - Roadmap and Milestones]], and a server
that cannot serve anything is a contradiction. Networking is also the phase that
proves the rest of the system: it exercises interrupts under load, DMA, the buffer
lifecycle, blocking and waking, timers, and concurrency, all at once and all in the
same code path.

It is honest to say this is also **the first phase to cut if the schedule slips.**
It is the largest self-contained chunk (10–14 weeks) and the least load-bearing for
the claim "we built an operating system." That decision is pre-agreed in
[[15 - Roadmap and Milestones]].

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 14.1 | Stage 14.1 - The Network Device Interface | Medium | One API over any NIC; a loopback device |
| 14.2 | Stage 14.2 - The virtio-net Driver | Hard | Packets in and out under QEMU |
| 14.3 | Stage 14.3 - The e1000 Driver | Hard | Packets in and out on real hardware |
| 14.4 | Stage 14.4 - Packet Buffers and the Receive Path | Hard | Zero-copy-ish buffers, an interrupt-driven RX queue |
| 14.5 | Stage 14.5 - Ethernet and ARP | Medium | Resolve IPs to MACs; answer ARP requests |
| 14.6 | Stage 14.6 - IPv4 and ICMP | Medium | **It answers ping** |
| 14.7 | Stage 14.7 - UDP and the Socket Layer | Hard | `socket`/`bind`/`sendto`/`recvfrom` |
| 14.8 | Stage 14.8 - TCP: Connection Management | **Hard** | The state machine, handshake, teardown |
| 14.9 | Stage 14.9 - TCP: Reliability and Flow Control | **Hard** | Retransmission, windows, RTT estimation |
| 14.10 | Stage 14.10 - DHCP and DNS | Medium | Get an address automatically; resolve names |
| 14.11 | Stage 14.11 - Network Utilities | Medium | `ping`, `ifconfig`, `netcat`, a tiny HTTP server |

---

## Deliverable

```
$ ifconfig
eth0  inet 10.0.2.15  netmask 255.255.255.0  ether 52:54:00:12:34:56

# from your host machine:
$ ping 10.0.2.15
64 bytes from 10.0.2.15: icmp_seq=1 ttl=64 time=0.4 ms

$ curl http://10.0.2.15:8080/
Hello from an OS we wrote.
```

---

## The hard parts, named in advance

**TCP is the largest single algorithm in this project.** It is a state machine with
eleven states, plus retransmission timers, plus RTT estimation, plus congestion
control, plus flow control, plus out-of-order reassembly. Stages 14.8 and 14.9 split
it deliberately: get connections opening and closing correctly *first*, then make
data transfer reliable.

Realistic scope for v1: a correct state machine, retransmission with exponential
backoff, a receive window, and Reno-style congestion control. **Not** in v1: SACK,
window scaling, timestamps, fast recovery beyond basic fast retransmit.

**Packet buffer lifetime is where kernels leak.** A packet arrives via DMA, is
processed by Ethernet, then IP, then TCP, then may be queued for a socket the user
has not read yet, then freed. Every layer must agree on who owns the buffer and when.
Getting this wrong leaks memory under load — which is exactly when you cannot afford
it. Design the ownership rule once, write it down, and enforce it in review.

**Everything is concurrent.** Packets arrive from an interrupt while a user task is
in `recv`. Retransmission timers fire from a timer context. On SMP, all of it happens
simultaneously on different cores. The locking discipline from
[[Phase 12 - Overview|Phase 12]] is not optional here.

**Byte order.** Network byte order is big-endian; x86 is little-endian. Every header
field needs `ntohs`/`htons`. A missing conversion produces a port number of 20480
instead of 80, and the bug is invisible until you print it in hex.

**Checksums.** IP, ICMP, UDP, and TCP each have one, and TCP/UDP checksums cover a
*pseudo-header* built from the IP header. This trips everyone. Test it in Tier 1
against known-good captured packets.

---

## Why both virtio-net and e1000

Same argument as two disk drivers in [[Phase 9 - Overview|Phase 9]]:

- **virtio-net** is what QEMU gives you by default and is far simpler — a
  paravirtual ring buffer with no real hardware quirks. Get the stack working
  against it first.
- **e1000** is a real Intel NIC found in enormous numbers of physical machines, and
  is also emulated by QEMU. It is your path to real hardware.

Writing the second one against an interface designed for the first is how you find
out whether Stage 14.1 was a real abstraction.

---

## Testing

| Tier | What |
|---|---|
| 1 | Checksum computation against captured packets; TCP sequence arithmetic including wraparound; the TCP state machine driven by a synthetic event sequence; ARP cache eviction |
| 2 | Loopback device round-trips a packet; the driver's TX/RX rings wrap correctly |
| 3 | QEMU user-mode networking: ping from host, a TCP echo round-trip, an HTTP GET, DHCP obtains a lease. Plus adversarial cases: malformed packets, a truncated header, a SYN flood |

**Wireshark on the host is your debugger for this phase.** QEMU can dump traffic to a
pcap file (`-object filter-dump,...`). Seeing your own malformed packet decoded is
worth ten hours of reading your own code.

---

## Read before you start

- **W. Richard Stevens, *TCP/IP Illustrated, Volume 1*.** The single best book on
  this material. If you read one thing, read this.
- RFC 9293 (TCP, the current consolidated spec), RFC 791 (IP), RFC 826 (ARP),
  RFC 768 (UDP), RFC 792 (ICMP)
- OSDev — *Network Stack*: <https://wiki.osdev.org/Network_Stack>
- OSDev — *Intel Ethernet i217* / e1000: <https://wiki.osdev.org/Intel_Ethernet_i217>
- virtio specification, "Network Device" chapter
- **lwIP** — a small, complete, readable TCP/IP stack. Excellent to compare against
  when your implementation misbehaves: <https://savannah.nongnu.org/projects/lwip/>

Previous: [[Phase 13 - Overview]] · Next: [[Phase 15 - Overview]]
