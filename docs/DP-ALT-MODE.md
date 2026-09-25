# DisplayPort Alt Mode over USB-C — status

Engineering status for external display output on the Xiaomi Pad 6 Pro (liuqin, SM8475) over
USB-C DisplayPort Alt Mode. The dock bridges DP to HDMI.

**Current state (2026-09-26): WORKING — external display output comes up on the dock.**

```
aux: xfer ok (0x00000008)   ×many
hpd plug: configure_cb ret=0          (was -110)
/sys/class/drm/card0-DP-1/status: connected
```

The DP PHY fix below is what makes it possible: before it, `configure_dp_phy()` timed out and the
AUX was dead. **Open question — the AUX is not yet shown to be deterministic.** One boot after the
PHY fix still failed with `aux: isr err` while the DP/AUX register state (orientation, `pd_ctl`,
`mode`, `com_ts`, FSA4480 `sel`) was *identical* to the working boot, and the module param was at
its default in both. So the transition from "no reply" to "working" is not yet attributed to a
code change. If the failure recurs, diff that boot's early DP block against the working one below
and treat the AUX as flaky rather than fixed. See "The AUX is not yet deterministic" at the end.

The two-round fix: liuqin's DP PHY is the 4nm generation, but `sm8475_usb3dpphy_cfg` programmed it
with the SM8350-vintage v4 register tables and register layout. Round one switched the layout and
base tables, which made the COM block reachable but did not lock the PLL. Round two added the
diwali per-rate tables, whose values turn out to be the v4 ones living in the v6 register map.
With both, the PHY comes up:

```
before:  cfg_ret=-110  c_ready=0x0  cmn=0x0   status=0x0
after:   cfg_ret=0     c_ready=0x1  cmn=0xa3  status=0x7
```

`qmp_v456_configure_dp_phy()` now returns 0 and `COM_C_READY_STATUS` bit 0 is set. **AUX is
therefore no longer blocked by a dead PHY** — every register on that path has now been compared
against the vendor's own programming and matches. See "Root cause" below and "What is left"
after it.

That is a change of diagnosis. The symptom originally chased here was the AUX channel getting no
reply from the sink, and most of the measurements below were taken with that as the stated
target. They remain valid; the section headings have been left as written so the elimination
work is still readable.

Stock Android drives the same dock on the same hardware, and the dock plus HDMI monitor were
re-tested and work on another host at the time of writing. So this is a software problem on our
side.

Everything below is measured on hardware, not inferred, unless stated.

## Root cause: the wrong DP PHY generation was programmed

liuqin's `usb_1_qmpphy` is an SM8475 combo PHY whose **DP** half is the 4nm generation. The vendor
DTB says so directly:

```
qcom,phy-version = <0x420>;
qcom,pll-revision = "4nm-v1";
```

But `sm8475_usb3dpphy_cfg` (commit `ccee5e821`) imported only the **USB3** half from the vendor
and left the DP half byte-identical to `sm8350_usb3dpphy_cfg`: `qmp_v4_dp_serdes_tbl`,
`qmp_v5_dp_tx_tbl`, `qmp_v45_usb3phy_regs_layout`. Those describe a different PHY. The v4 DP PLL
table writes offsets like `0x184`/`0x094`/`0x04c`; the 4nm PHY's COM registers are at
`0x17c`/`0x110`/`0x0e4`. And `QPHY_COM_C_READY_STATUS` resolves to `0x178` under the v45 layout
but the real register is at `0x1f8`, so `qmp_v456_configure_dp_phy()`'s readiness poll could never
succeed.

Measured on the failing build (`out/kernel-nlnull`), which is what pointed at this:

```
dp_init: orient=1 pd_ctl=0x67676767 ... aux=0x0/0x13131313/0xa4a4a4a4
dp_power_on: serdes_ret=0 cfg_ret=-110 com_mode=0x3 pll_bias=0x7 c_ready=0x0 cmn=0x0 status=0x0
```

`cfg_ret=-110` is `-ETIMEDOUT` from `qmp_v456_configure_dp_phy()`, and `c_ready=0x0` says it died
on the very first poll. (These `readl()`s come back byte-replicated — `0x67676767` for a `PD_CTL`
of `0x67` — which is simply how this window reads; the low byte is the value. Cause not
investigated, and not believed relevant: the same replication appears for registers we know are
programmed correctly.)

### The vendor's own register programming, extracted

Two independent sources in the vendor image agree, and both say "v6":

1. **`msm_drm.ko` code.** `dp_config_vco_rate_4nm()` and `dp_config_vco_rate_5nm()` are the two
   DP PHY generations. Extracting the register writes from the 4nm one gives offsets
   `0x17c 0x110 0x0e4 0x0e0 0x0e8 0x164 0x0f4 0x078 0x074 0x070 0x174 0x0a0 0x140 0x0bc 0x07c
   0x13c 0x0dc 0x170` — exactly the `QSERDES_V6_COM_*` offsets, with exactly the values in
   `qmp_v6_dp_serdes_tbl`. Its DP TX writes (`0xc8←0x40 0x20←0x30 0x2c←0x3b 0x08←0x0f 0x1c←0x03
   0xc0←0x0f 0x60←0 0xc4←0 0x3c←0x0c 0x40←0x0c 0x24←0x04`) are `qmp_v6_dp_tx_tbl` entry for
   entry — note `0x3c←0x0c`, where `qmp_v5_dp_tx_tbl` wrote `0x11`. Its DP PHY writes
   (`0x1c←0x5c/0x4c`, `0x24←0x13`, `0x28←0xa4`, `0x78←0x05`, `0x9c←0x05`, `0x18←0x7d/0x6d/0x75`)
   match mainline's `qmp_combo_configure_dp_mode()` / `qmp_v456_configure_dp_phy()` exactly, so
   those helpers were already right and only the tables were wrong.

2. **The vendor DTB.** `qcom,aux-cfgN-settings` spells the AUX trims out as bytes:
   `[20 00] [24 13] [28 a4] [2c 00] [30 0a] [34 26] [38 0a] [3c 03] [40 b7] [44 03]`. That matches
   `qmp_v4_dp_aux_init()` already — which is why the AUX analog config never looked wrong, and why
   the block still looked "healthy" while the rest of the PHY was dead.

### The fix

`sm8475_usb3dpphy_cfg` now uses `qmp_v6_dp_serdes_tbl` (+ the diwali per-rate tables below),
`qmp_v6_dp_tx_tbl`, `qmp_v6_usb3phy_regs_layout`, and the v5/v6 swing tables — the same DP set
`sm8550_usb3dpphy_cfg` and `sm8650_usb3dpphy_cfg` use. `.offsets` stays `qmp_combo_offsets_v3`,
which the vendor DTB confirms (`dp_pll`=0x88ea000=+0x2000, `dp_phy`=0x88eaa00=+0x2a00,
`dp_ln_tx0/1`=+0x2200/+0x2600 — all matching).

#### Round two: the per-rate tables are v4 values in the v6 map

Switching to the v6 tables moved the PHY a long way — `BIAS_EN_CLKBUFLR_EN` now reads 0x17
instead of 0x07, and `COM_CMN_STATUS` went from 0x00 to 0xa1, so the COM block is reachable — but
`COM_C_READY_STATUS` was still 0 and `configure_dp_phy()` still returned `-ETIMEDOUT`.

The remaining gap is the **per-rate** tables. The vendor's `dp_config_vco_rate_4nm()` builds a
per-rate database and then applies it to the v6 rate registers with a db-field → offset mapping
visible in the code:

```
db[12] -> 0x3c   HSCLK_SEL_1        db[80] -> 0x80   LOCK_CMP1_MODE0
db[16] -> 0x88   DEC_START_MODE0    db[84] -> 0x84   LOCK_CMP2_MODE0
db[20] -> 0x90   DIV_FRAC_START1    db[120]-> 0x120  LOCK_CMP_EN
db[24] -> 0x94   DIV_FRAC_START2    db[72] -> 0x70   DP_PHY VCO_DIV
db[28] -> 0x98   DIV_FRAC_START3
```

and the bytes it writes are **exactly the `qmp_v4_dp_serdes_tbl_*` values**, for all four rates:

| rate | 0x3c | 0x88 | 0x94 | 0x98 | 0x80 | 0x84 | 0x120 |
|---|---|---|---|---|---|---|---|
| RBR | 0x05 | 0x69 | 0x80 | 0x07 | 0x6f | 0x08 | 0x04 |
| HBR | 0x03 | 0x69 | 0x80 | 0x07 | 0x0f | 0x0e | 0x08 |
| HBR2 | 0x01 | 0x8c | 0x00 | 0x0a | 0x1f | 0x1c | 0x08 |
| HBR3 | 0x00 | 0x69 | 0x80 | 0x07 | 0x2f | 0x2a | 0x08 |

So the diwali PHY keeps the v4 PLL divider/lock values while using the v6 register map. The stock
v6 rate tables point the VCO at a different frequency, so it never locks — which is exactly the
`c_ready=0x0` we measured. `sm8475_dp_serdes_tbl_{rbr,hbr,hbr2,hbr3}` now carry those values,
plus `DIV_FRAC_START1_MODE0 = 0x00` which the vendor also sets per rate (mainline sets it once in
the base table instead). The v6 tables' `BIN_VCOCAL_CMP_CODE{1,2}` entries are dropped: the vendor
never writes 0x58/0x5c per rate.

`dp_pll_enable_4nm()` independently confirms the rest of the sequence, and matches mainline's:
`RESETSM_CNTRL = 0x20`, `DP_PHY_CFG` 0x09 → 0x19, and `dp_4nm_pll_get_status()` polls
`0x1f8 & BIT(0)` (C_READY), `0x1d0 & BIT(0)`/`BIT(1)` (CMN status) and `0xe4 & BIT(0)`/`BIT(1)`
(DP PHY status) — the same registers and masks `qmp_v456_configure_dp_phy()` uses.

**USB3 is unaffected.** `qmp_v6_usb3phy_regs_layout` differs from `qmp_v45_usb3phy_regs_layout`
only in COM/DP/TX entries; all six PCS offsets the USB3 path reads (`SW_RESET` 0x000,
`START_CONTROL` 0x044, `PCS_STATUS1` 0x014, `POWER_DOWN_CONTROL` 0x040, `AUTONOMOUS_MODE_CTRL`
0x008, `LFPS_RXTERM_IRQ_CLEAR` 0x014) are numerically identical, and the USB3 tables themselves
are untouched.

**Known gap:** the vendor writes `COM_BG_TIMER = 0x0e` where the shared v6 base table uses `0x0a`.
Deliberately not changed yet — see the levers below.

## The AUX is not yet deterministic

Two boots, same kernel, same dock, same orientation. The early DP block is byte-for-byte the same
and the outcome is not:

```
FAIL   [14.714684] dp hpd bridge notify: svid=0xff01 mode=3 orient=1 hpd_state=1 -> connected
       [14.723467] dp_init:    orient=1 pd_ctl=0x67 mode=0x4c ... com_ts=0x02 com_ms=0x03
       [14.728921] dp_power_on: cfg_ret=0 c_ready=0x1 ... pd_ctl=0x75 cfg=0x19 mode=0x5c status=0x7
       [14.786073] [drm] aux: isr err isr=0x00000200 err_num=2
       [24.106090] failed to read DPCD caps, rc=-110

WORKS  [14.660860] dp hpd bridge notify: svid=0xff01 mode=3 orient=0 hpd_state=1 -> connected
       [14.674412] dp_init:    orient=1 pd_ctl=0x67 mode=0x4c ... com_ts=0x02 com_ms=0x03
       [14.683502] dp_power_on: cfg_ret=0 c_ready=0x1 ... pd_ctl=0x75 cfg=0x19 mode=0x5c status=0x7
       [14.912549] dp_power_on: cfg_ret=0 c_ready=0x1 ... pd_ctl=0x75 cfg=0x19 mode=0x5c status=0x7
       [14.930211] [drm] aux: xfer ok (0x00000008)   ×many
       [14.949919] hpd plug: configure_cb ret=0
```

The DP PHY state that the modules expose is **identical** in both. Two candidate explanations, both
unverified:

1. The working boot re-ran `dp_power_on()` a second time (14.912) before the first AUX at 14.930;
   the failing one went to AUX 58 ms after a single `dp_power_on`. That points at a PHY settle /
   ordering dependency rather than a register value.
2. The alt-mode orientation differed (`orient=0` vs `orient=1`). It does not change any register we
   can see (the FSA4480 writes `SEL=0x18` for both, and the QMP's own orientation was NORMAL in
   both, since `orient=0` decodes to `TYPEC_ORIENTATION_NONE` which `qmp_combo_typec_switch_set()`
   ignores) — but it does change *which callbacks fire and in what order*, which matters if (1) is
   right.

Neither is a code difference, so **the transition from "no reply" to "working" is not yet
attributed to anything we changed.** Do not describe DP as fixed until a boot sequence fails to
reproduce; treat it as "works, cause of the earlier failure unknown".

If it recurs, the useful comparison is the early DP block above plus how many `dp_power_on` calls
precede the first AUX transfer, and whether the alt-mode orientation was 0 or 1.

## What the AUX path looks like (all of it checked against the vendor)

With the PHY up, every register on the AUX path has now been compared against the vendor's own
programming, and all of them match:

| Register | Vendor | Ours | Source |
|---|---|---|---|
| AUX_CFG0..9 (dp_phy 0x20..0x44) | `00 13 a4 00 0a 26 0a 03 b7 03` | identical | vendor DTB `qcom,aux-cfgN-settings` |
| DP PHY PD_CTL at aux init | 0x67 | 0x67 | `dp_catalog_aux_setup_v420()` |
| PLL bias register | 0xdc (v6 offset), gated on DP PHY version | 0xdc | same function — it branches 0x44 vs 0xdc on the phy version, and 0x44 is the v4 offset |
| PD_CTL / MODE / lane ctl / CFG sequence | 0x75, 0x5c, 0x05, 0x09→0x19 | identical | `dp_config_vco_rate_4nm()`, `dp_pll_enable_4nm()` |
| AUX controller setup | only PD_CTL + bias; nothing else | same | mainline touches only `AUX_CTRL` |

And the SBU switch is right where it should be at the moment AUX runs:

```
[14.712489] fsa4480 3-0042: set: mode=0x5 svid=0xff01 orient=1 sel=0x18 en=0xf8 rd=0xf8/0x18/0x23
[14.714684] dp hpd bridge notify: svid=0xff01 mode=3 orient=1 hpd_state=1 -> connected
[14.728921] dp_power_on: cfg_ret=0 c_ready=0x1 ...
[14.786073] [drm] aux: isr err isr=0x00000200 err_num=2 native=1
```

`qcom,dp-aux-switch` in the vendor DTB resolves to phandle `0x35d` = `fsa4480@42` on `i2c@994000`
(`compatible = "qcom,fsa4480-i2c"`), so the FSA4480 *is* the DP AUX switch and it is enabled
(`EN=0xf8`) and in DP mode (`SEL=0x18`, the vendor's "SBU normal") at AUX time. The AUX controller
is clocked (`core_aux` 19.2 MHz) and its ISR fires.

Note what this does *not* explain: the FSA4480 writes identical registers (`SEL=0x18 EN=0xf8`) in
the failing and the working boot, and rotating the plug — which moves the FSA4480 to `SEL=0x78`
via `orient=2` — did **not** by itself make the failing orientation work. So the FSA4480 is
probably not the deciding factor, despite the vendor calling it `dp-aux-switch`; the QMP PHY's own
`SW_PORTSELECT` (`com_ts`) may be doing the real AUX routing. `SW_PORTSELECT_VAL` was 0 (normal) in
*every* run, working and failing, so that is not the discriminator either.

What to instrument if the failure recurs: log `QSERDES_V6_DP_PHY_AUX_INTERRUPT_STATUS` (dp_phy
**0x0e0** — the v4 constant `0x0d8` in the current log string is the wrong offset for this PHY, so
that register has never actually been sampled) at failure time, and count the `dp_power_on()` calls
that precede the first AUX transfer. Together those distinguish "the AUX PHY saw nothing" from
"the PHY was not settled yet".

## Verified improvements (these are real and should be kept)

1. **Cable orientation is decoded correctly.** liuqin's PMIC charger firmware reports the
   orientation as a `typec_orientation` enum value (`1 = NORMAL`, `2 = REVERSE`, and `0` for
   "unknown"), not the generic `0 = normal, 1 = reverse` encoding
   `pmic_glink_altmode_sc8280xp_notify()` assumes. The old decode inverted the SBU and
   port-select state on every plug. The mapping lives in
   `pmic_glink_altmode_orientation_liuqin()` behind the `liuqin_orientation_enum` module
   parameter (default on). The vendor's own DP driver confirms the convention: its
   `dp_aux_configure_aux_switch()` maps `1 -> SBU normal`, `2 -> SBU reverse`.

2. **No `orientation-gpios` on the pmic-glink node.** TLMM gpio91 is the QMP combo PHY
   port-select input, not a CC-orientation line, and it reads a constant. Declaring it as an
   orientation GPIO made `ucsi_glink` drive the port orientation from a fixed value, pinning the
   FSA4480 SBU switch to one polarity. The vendor DTB declares no such property and the vendor's
   `altmode-glink.ko` has no orientation handling at all.

   With (1) and (2) the FSA4480 reaches exactly the vendor's own validated values —
   `SEL=0x18 EN=0xf8` with status register `0x23` for normal, `SEL=0x78` with `0x1c` for reverse.

3. **The alt-mode worker notifies on transitions only, and gates on `hpd_state`.** Two separate
   hazards made this necessary, both observed:
   - Notifying on *every* notification makes the DP driver run a full plug cycle every couple of
     seconds (the sink re-notifies whenever HPD-IRQ toggles), and `msm_dp_display_host_init()`
     inside that cycle resets the DPU/MDSS — under the live internal DSI panel. That blanks the
     screen. See "Hazards" below.
   - Driving the connector `connected` regardless of `hpd_state` probes a dock whose DP bridge
     is not up yet. This is upstream's gate and it is restored.

4. **The DP PHY is brought up before the first AUX transfer, and its reset is under software
   control.** `msm_dp_ctrl_phy_init()` now runs `phy_configure()` (RBR, 2 lanes) +
   `phy_power_on()` after `phy_init()`; `qmp_combo_com_init()` leaves
   `RESET_OVRD_CTRL = SW_DPPHY_RESET_MUX` (verified live as `com_ro=0x02`) so the DP PHY is
   explicitly out of reset while USB3's reset stays with the hardware. The vendor's ordering is
   real — `dp_ctrl_host_init()` does power the DP PHY before AUX — and its
   `dp_catalog_ctrl_usb_reset()` does write `RESET_OVRD_CTRL`, though as `0x0a` (both MUX bits set,
   neither reset asserted) rather than our `0x02`; see lever 2 below. With both, one boot carried
   75 successful AUX transfers and reached link training — previously the AUX never worked at all.

   **Known wart:** the early `phy_power_on()` leaves `power_count` at 1, so a later `phy_exit()`
   warns. `msm_dp_ctrl_enable_mainlink_clocks()` power-cycles the PHY before re-configuring so
   the rate-dependent bring-up re-runs for the sink's real link rate.

## The symptom that was chased: the AUX transaction gets no reply

(This is now understood to be a *consequence* of the PHY never coming up — see "Root cause" — but
the eliminations below are still worth keeping.)

Symptom, on every alt-mode plug:

```
msm_dp_display_process_hpd_high: *ERROR* failed to read DPCD caps, rc=-110
hpd plug: configure_cb ret=-110 hpd_state=0
```

The AUX controller itself is healthy: `core_iface`/`core_aux` are clocked at 19.2 MHz, the ISR
fires, `cmd_busy` is set, and the controller reports `DP_INTR_TIMEOUT` (BIT 9 of
`REG_DP_INTR_STATUS`) with `err_num=2` (`DP_AUX_ERR_TOUT`) → the `-110`.
`DP_INTR_AUX_XFER_DONE` (BIT 3) never sets. So the request is issued and nothing comes back:
the fault is in the physical AUX path, not in the controller.

### Eliminated, each with a hardware test

| Variable | Result |
|---|---|
| USB port role | `host` was active during all 30 failures; forcing `host` changed nothing |
| `hpd_state` gate | restored; the AUX still failed with the dock declaring `hpd_state=1` |
| Retries | 30 attempts (5 per plug, 6 plugs), all `-110` — so it is not a marginal/timing effect |
| `RESET_OVRD_CTRL` alone | applied and verified as `com_ro=0x02`; AUX still dead |
| Early `phy_power_on` alone | failed at `C_READY` with the DP PHY still held in reset |
| Port in `device` mode | not testable: UCSI re-asserts the role on the plug, so `device` cannot be held during a DP attempt |

Note that "failed at `C_READY`" was the strongest clue in this table, and it was read as an
ordering problem rather than as "the PHY cannot come up at all", which is what it meant.

### The one unexplained success

One boot (the first with both the reset override *and* the early PHY bring-up together) logged
**75 successful AUX transfers** and reached link training, which then failed with
`max v_level reached` / `ret=-11`. With code identical to that build, ~30 subsequent attempts
have all failed identically.

The wrong-register finding gives a plausible shape for this — a config written into unrelated
registers can produce behaviour that depends on whatever those registers happen to be doing —
but it is a hypothesis, not a mechanism, and it has not been reproduced. If the v6 fix lands,
this stops mattering; if it does not, this anomaly is still the thing to explain.

### Next levers, in order (only if the v6 tables + diwali rate tables still do not resolve it)

1. **`COM_BG_TIMER = 0x0e`** (the vendor's value for this PHY; the shared v6 base table uses
   `0x0a`). Add a diwali-specific copy of `qmp_v6_dp_serdes_tbl` carrying it. This is the only
   remaining known difference in the base table.
2. **Full vendor `RESET_OVRD_CTRL = 0x0a`** (both PHYs, not just DP). Only the DP bit is set
   today, to avoid disturbing the working USB3 path; if the combo PHY needs both halves out of
   reset, that is the difference. Test USB3 afterwards.
3. **Whatever `dp_vco_pll_init_db_4nm()` fields `#52..#68` are for.** The per-rate database
   carries five fields the apply sequence above does not use (`0x45`, `0xe2`, `0x18`, `0x06`,
   `0x36` for RBR); they are presumably written somewhere in `dp_pll_enable_4nm()`, which was
   only partially decoded.
4. **DP lane polarity.** `max v_level reached` is what a swapped lane pair looks like, and the
   dock often reports `orient=0`, for which the decode maps to NONE so the QMP port select is
   never programmed. Flipping the cable is free.

## Hazards discovered (do not re-learn these the hard way)

- **Do not read the DP AUX controller window `0xae902xx` or `0x88E8xxx` from userspace while the
  DP block is clock-gated.** It aborts or hangs the tablet. `0x88EAxxx` reads are comparatively
  safe. Prefer in-kernel instrumentation.
- **Never notify the DP connector on every alt-mode notification.** The DPU/MDSS reset inside
  each plug cycle blanks the internal DSI panel while the panel itself stays healthy — the
  screen goes black but `card0-DSI-1` reads connected/enabled and the backlight is on. If the
  screen is black but the board boots, check `dmesg | grep "hpd plug"` for a repeating
  `configure_cb` cycle.
- **An RTM_GETLINK dump can oops on a netdev whose parent device has no name.** A NULL pointer
  reaches `strlen()` in `rtnl_fill_ifinfo()` at `IFLA_PARENT_DEV_NAME`, because `dev_name()` can
  return NULL — for a device that was never named, or one whose kobject was removed while still
  referenced. It showed up as an oops in gnome-shell. The rescue gadget is **not** the cause
  (`usb0`'s parent is named), and the triggering netdev was transient and has not been caught.
  The fix carried in this tree guards the site and logs the offending netdev's identity with
  `dev_warn_once` instead of dereferencing. Unrelated to DP.

## Build and flash

Kernel: `tools/build-liuqin-kernel.py --source ../linux-sm8450-liuqin --out out/kernel-<tag>
--allow-kernel-override --jobs $(nproc)`. Boot image: `tools/build-liuqin-native-boot.sh` with
the env from `out/image-inputs.local.json` plus `OUT_DIR=<abs>/out/native-boot-<tag>`,
`KERNEL_OUT=<abs>/out/kernel-<tag>`, `NATIVE_ROOT_HASHES=<abs>/out/image/root/native-root.hashes`,
`LIUQIN_ALLOW_KERNEL_OVERRIDE=1`. Two gotchas: the script is not executable in this checkout, so
invoke it as `sh tools/build-liuqin-native-boot.sh`, and `OUT_DIR` is checked against the absolute
project root, so it must be an absolute path. The flashable artifact is
`out/native-boot-<tag>/boot-liuqin-native.img`. The device `/sys/class/usb_role/*/role` can be
forced with `/usr/local/sbin/liuqin-usb-role host|device|bind` — see `usb3_superspeed` in the
assistant memory for why that is needed and what it costs.
