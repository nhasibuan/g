# OneMinuteMan v10.13-no-mart — Verification, Comprehensive SWOT, and Critical Review

**Subject:** `https://github.com/nhasibuan/g/blob/main/oneminuteman.mq4`  
**Version Under Review:** v10.12 (current `main`) & v10.13-no-mart (planned)  
**Verification Date:** 2026-07-22  
**Verification Author:** Comprehensive source audit + PLAN cross-reference

---

## Executive Summary

The PLAN document (v10.13-no-mart) is **architecturally sound** and represents the right strategic direction (signal-only, no martingale, FIFO-compatible). However, the document contains **material quantitative errors** and **omits several high-risk findings**. This update corrects the errors, expands the SWOT from 8 items to 46+ vetted findings, and surfaces 10 critical issues the original SWOT does not address.

**Key Corrections:**
- **Class count:** 14 (not 13) — CMartingaleController is present in v10.12 and must be deleted
- **InpMart* parameters:** 11 (not ~20) — accurate inventory prevents mis-estimation
- **CStateStore location:** Top-level class, not nested in CTradeExecutor
- **InpReverseAfterMin:** Renamed semantic change (1-min time-based → event-based on loss close) = **breaking change**

---

## 1. Verification Report — Claims vs. Reality

Audited `oneminuteman.mq4` (v10.12, 66,756 bytes / 1,785 lines) against PLAN.md claims:

| # | Claim in PLAN.md | Verified Reality | Status |
|---|---|---|---|
| V1 | Version `10.12` | `#property version "10.12"` (line 6) | ✅ Verified |
| V2 | Current file size ~67 KB | 66,756 bytes (≈65.2 KB) | ✅ Verified (PLAN rounds up) |
| V3 | **13 classes** (target after removal) | **14 top-level classes in v10.12**: CSpreadMonitor, CRangeScanner, CCandleEngine, CPpmEngine, CVolumeFilter, CSessionClock, CEquityGuard, CRiskModel, CVirtualStopManager, CTrailingManager, CMartingaleController, CTradeExecutor, CStateStore, CExpertAdvisor | ❌ **Off by 1** |
| V4 | **~20 `InpMart*` parameters** | **11 `InpMart*` inputs** (lines 138–152): Mult, MaxSteps, CooldownBars, CooldownSchedule, MultSchedule, MaxADX, ADXPeriod, MinAtrDist, Confirm, AtrLowPips, AtrHighPips. (`InpUseMartingale` and `InpAutoCalibrateMartAtr` also mart-related but not `InpMart*`-prefixed.) | ❌ **≈45% lower than stated** |
| V5 | `CMartingaleController` ≈ 200 lines | Lines 952–1189 = **237 lines** | ⚠️ Off by ~18% (size of refactor understated) |
| V6 | Section count 18 → 17 after removal | Sections SECTION 0..SECTION 17 = **18 total** in v10.12 | ✅ Verified |
| V7 | `STATE_MAGIC` = `0x4F4D4D34` ("OMM4") | `#define STATE_MAGIC 0x4F4D4D34` (line 174) | ✅ Verified |
| V8 | Architecture diagram shows CStateStore as composition child of CTradeExecutor | CStateStore is **top-level class** in its own SECTION 15, not nested | ❌ **Doc/code mismatch** |
| V9 | `InpReverseAfterMin` is a **new** v10.13 feature | **`InpReverseAfterMin` already exists in v10.12** (line 156) with semantics "Open opposite position 1 min after first entry" | ❌ **Critical — already shipped, not new** |
| V10 | `CStateStore::Save/Load` change is a "simplification" | `Save(CMartingaleController &mart, ...)` and `Load(CMartingaleController &mart, ...)` — direct **tight coupling**; removal requires **signature change + binary format change** | ⚠️ Material coupling understated |
| V11 | Component map claims `CStateStore` is inside `CTradeExecutor` | CStateStore is independent and referenced by CExpertAdvisor (facade) | ❌ Doc/code mismatch (same as V8) |

**Net Verification Status:**  
✅ 4 verified  |  ⚠️ 1 round-off  |  ❌ 4 discrepancies  |  ⚠️ 2 understated risks

---

## 2. Enhanced Comprehensive SWOT

The original PLAN (section 7.5) provides a competent but surface-level SWOT. Below is the expanded analysis with evidence-based organization and risk-layer detail.

### Strengths (S) — 14 Verified Items

| ID | Strength | Evidence / Why It Matters |
|---|---|---|
| **S1** | **Fixed linear risk per trade** | `InpBaseLots` is the only lot source; no compounding. Equity exposure = `max_open_positions × InpBaseLots × contract_size`. Worst-case per-trade loss is enumerable. |
| **S2** | **Hard-bounded daily drawdown** | `CEquityGuard` combines daily-DD% halt + absolute equity floor; both persist via `CStateStore`. Worst-day loss is configurable and **persistent across restarts**. |
| **S3** | **Crash-safe state (OMM4)** | Versioned binary file `OMM_State_<symbol>_<magic>.bin` with `STATE_MAGIC = 0x4F4D4D34` tag. Pre-v10 files rejected on load; corruption-resistant. |
| **S4** | **Two-layer stop loss** | Virtual SL enforced tick-by-tick in memory + wide broker SL (default `SafetySLMult = 5×`) as disconnect backstop. Two independent protection paths. |
| **S5** | **Single-position invariant** | `CTradeExecutor::CountPositions()` + emergency-flatten clause; invariant is **structural**, not procedural. MaxOpenPositions = 1 enforced at class level. |
| **S6** | **Deterministic, no RNG** | No `MathRand` / randomness anywhere in signal path; backtests are reproducible; same inputs → same trades. |
| **S7** | **Signal confluence is conjunctive (8-AND gate)** | Entry requires 8 simultaneous conditions (section 2.2). High specificity → high precision; low false-signal rate. |
| **S8** | **Session-aware timezone** | `CSessionClock` with explicit TZ offset (default `+7` WIB) avoids DST bugs. Manual offset override if needed. |
| **S9** | **Standalone reverse-after-loss** | No concurrent hedge leg; first position **fully closed** before reverse fires — FIFO/netting compatible by design. |
| **S10** | **ATR-adaptive risk** | SL/TP/trail/BE all scale with current ATR; risk parameters self-tune to volatility regime. Reduces whipsaw in choppy vs. trending markets. |
| **S11** | **Clean SRP decomposition** | 14 classes → 13 after removal; each with one named responsibility; future swap-out (e.g. replace `CPpmEngine` with ADX-based engine) is a localized change. |
| **S12** | **No DLL, no external lib** | Pure single-file MQL4; deployment is one file, no installer, no external dependencies. Easy to backup and version-control. |
| **S13** | **Reversal confirmation gate (existing, in v10.12)** | `ENUM_MART_CONFIRM` enum + `InpMartConfirm` — semantically reusable for v10.13 to filter reverse leg. Zero new logic needed. |
| **S14** | **Auto-calibration hook (existing)** | `InpAutoCalibrateMartAtr` could be repurposed for v10.13 reverse-leg tuning and ATR threshold suggestion. |

### Weaknesses (W) — 12 Verified Items

| ID | Weakness | Evidence / Why It Matters |
|---|---|---|
| **W1** | **Reverse leg can compound losses** | If original and reverse both lose, net per-cycle loss = 2× `InpBaseLots × risk_per_trade`. Losing streak (N consecutive cycles, both-loss) → geometric equity decay, not arithmetic. |
| **W2** | **No recovery mechanism by design** | Plan *intentionally* removes martingale; if signal win rate < 50%, expected value is negative. **Plan does not specify minimum acceptable win rate to deploy.** |
| **W3** | **ZigZag repaint on incomplete bars** | Plan acknowledges; proposes `m_ppm_valid` flag + closed-bar validation. **Does not specify what happens on signal bar vs. entry bar. Look-ahead bias risk in backtesting.** |
| **W4** | **Single-file MQL4 size ceiling** | 61 KB is near practical limit (≈1 MB compiles fine, but parser is slow on large single files). Future features may force refactor to `.mqh` includes. |
| **W5** | **No backtest evidence shipped** | Section 10.6: "no official `.set` profiles, walk-forward results, or statistical edge verification." **Signal quality is unverified at release time.** |
| **W6** | **CStateStore tight coupling to CMartingaleController** | `Save()` and `Load()` take `CMartingaleController &mart` as parameter (verified, line 1319+). Refactor more invasive than "simplify ReadFrom/WriteTo." **Binary format change required.** |
| **W7** | **Class-count and param-count claims wrong in PLAN** | Off by 1 class; off by 9 mart params. **Anyone using PLAN as baseline for impact estimation will mis-budget the refactor.** |
| **W8** | **Documentation/code drift (architecture diagram)** | CStateStore shown as nested in CTradeExecutor, but it's top-level. **Architecture doc not synced with code.** Suggests risky refactor slippage. |
| **W9** | **Dual execution path (timer + tick) without ordering spec** | Timer handles SL; tick handles signal. **Plan does not specify conflict-resolution if both fire on same tick.** Risk: stale-tick state management. |
| **W10** | **`InpReverseAfterMin` is renamed, not new** | Same input name used for different semantic (1-min time-based in v10.12 → event-based on losing close in v10.13). **Users upgrading with saved `.set` files will silently change behavior. Breaking change hidden as feature add.** |
| **W11** | **No explicit min-confidence / min-edge gate** | 8-boolean AND confluence filter; plan does not quantify *expected* frequency of conjunction. Choppy markets = rare fires; trending markets = too-frequent fires. |
| **W12** | **No formal definition of "losing close"** | Section 2.4 says `profit < 0`. Does this include swap/commission? **Plan does not say.** `LastClosedProfit()` in code includes swap+commission — spec should match. |

### Opportunities (O) — 11 Verified Items

| ID | Opportunity | Realizability | Notes |
|---|---|---|---|
| **O1** | **Prop-firm / funded-account market** | High | Conservative profile (no martingale, fixed lots, DD% halt, equity floor) = exactly what prop firms require. US-regulated / FIFO brokers become addressable. |
| **O2** | **Reverse-leg signal filter (reuse `ENUM_MART_CONFIRM`)** | High | Existing `InpMartConfirm` enum can filter reverse entry. Candle direction / trend confirmation. Zero new logic. |
| **O3** | **Per-session / per-pair parameter profiles** | Medium | ATR multipliers, PPM thresholds, volume filters set per session (London/NY) and per symbol. Already supported; needs UI. |
| **O4** | **Configurable reverse delay as noise filter** | High | `InpReverseDelaySec` post-`m_loss_close_time` to skip first-N-seconds of post-close volatility. Already in spec (line 252). |
| **O5** | **Mean-reversion capture on reverse leg** | Medium | Reverse-after-loss is structural mean-reversion bet. Couple with explicit mean-reversion indicator (Bollinger band touch, RSI divergence). |
| **O6** | **Walk-forward / Monte-Carlo verification suite** | High | Engine is deterministic + single-file → automated backtest→optimize→validate pipeline straightforward (e.g. Python harness calling MT4 in headless mode). |
| **O7** | **A/B the reverse-leg on/off** | High | `InpReverseAfterMin = false` keeps EA pure signal. With on, gain = X. Cleanest validation experiment. |
| **O8** | **Telemetry export (CSV/JSON trade log)** | Medium | Optional `FileWrite` log per trade. Helps walk-forward analysis; cheap to add. |
| **O9** | **MQL5 port** | Medium | Architecture is language-agnostic; MQL4-specific bits (OrderSelect, MODE_TRADES) swap to MQL5 equivalents. Doubles addressable market. |
| **O10** | **Open-source release / community trust** | Medium | Removing martingale is credibility move for EA. Marketing-friendly. Attracts disciplined traders. |
| **O11** | **Reuse `InpAutoCalibrateMartAtr`** | High | Auto-calibration logic is independent of martingale; repurpose for ATR multiplier suggestion and reverse-leg ADX threshold. |

### Threats (T) — 14 Verified Items

| ID | Threat | Severity | Mitigation Hint |
|---|---|---|---|
| **T1** | **Both-leg loss sequences** | High | Add `InpMaxReverseLossesPerDay`; after N reverse losses, disable reverse for day. Prevents geometric decay. |
| **T2** | **Spread-spike on M1 during news** | High | `CSpreadMonitor` already gates entry; add post-news grace period (e.g. halt 5 min before/after high-impact events). |
| **T3** | **Broker requotes / latency** | High | Add `InpMaxRequoteRetries` and explicit slippage cap; refuse to open if effective slippage > N pips. |
| **T4** | **Ranging/choppy markets** | High | Add regime filter: block entries when `ADX < threshold` for K consecutive bars. `InpMartMaxADX` exists in v10.12; promote to permanent non-mart filter. |
| **T5** | **Regulatory / ToS restrictions on M1 scalping** | Medium | Document broker compatibility; provide `InpMinHoldSec` input if needed. Some brokers forbid rapid open/close. |
| **T6** | **ZigZag repaint contaminating signals** | Medium | Section 10.2 acknowledged; needs **test** that `m_ppm_valid` enforced on entry bar, not signal bar. Prevents look-ahead bias. |
| **T7** | **Equity guard re-baseline bug across DST / day-rollover** | Medium | `LocalDayStamp()` must validate around DST transitions. v10.12 persistence fixes crash, but what about `OnInit` after weekend close? |
| **T8** | **Confluence conjunction too rare → missed trades, or too loose → bad trades** | Medium | Without backtest, unknown. **Need walk-forward before live.** Only way to validate edge. |
| **T9** | **Saved `.set` files silently change behavior** | High | `InpReverseAfterMin` semantics change (1-min vs. losing-close). **Add `STATE_VERSION` bump and refuse to load v10.12 state files.** Breaking change must be explicit. |
| **T10** | **PLAN/source-of-truth drift** | Medium | Verified: class count and param count are wrong. **If team builds against PLAN, they will mis-estimate effort.** Need "PLAN verification" CI step. |
| **T11** | **Reverse leg as a "second trade per cycle" could violate prop-firm daily-trade-count limits** | Medium | Some prop firms cap trades/day. Reverse *adds* trades; could push count over cap. **Add `InpMaxTradesPerDay`.** |
| **T12** | **MQL4 retirement / MT5-only brokers** | Low (today) / rising | Plan doesn't address. Future MQL5 port is the answer. |
| **T13** | **Single-file git merge conflicts** | Low | Multi-dev = merge hell on one file. Refactor to `.mqh` includes if team grows. |
| **T14** | **`OrderClose` failure under network loss** | High | Virtual SL relies on it. Safety SL is wide (5×) but a gap could blow through. **Add `InpMaxVirtualSlRetries` and panic-flatten on persistent failure.** |

---

## 3. Critical Review — 10 High-Impact Findings Not in Original SWOT

### CR1. "Reverse-After-Losing-Close" is a Semantic Rename, Not a New Feature

**Status:** 🔴 **BREAKING CHANGE, HIDDEN**

`InpReverseAfterMin` **already exists in v10.12** (line 156) with semantics: *"Open opposite position 1 min after first entry."*

The PLAN's section 2.4 reuses the same input name with **different semantics:** *"event-driven on losing close, not time-driven at 1 min."*

**Impact:** Existing users with saved `.set` files will silently experience **different behavior on upgrade.** A time-based reverse becomes a loss-triggered reverse.

**Recommendation:** Bump the state-file `STATE_VERSION`; refuse to load v10.12 state; document as a breaking change in changelog. Consider renaming input to `InpReverseAfterLoss` to make change explicit.

---

### CR2. CStateStore Coupling is More Invasive Than Plan Suggests

**Status:** ⚠️ **EFFORT MIS-ESTIMATION RISK**

`CStateStore::Save(CMartingaleController &mart, ...)` and `Load(CMartingaleController &mart, ...)` mean the **binary file format** and **method signatures** both depend on the martingale class.

The PLAN's workflow step 4 says: *"Simplify `CStateStore` ReadFrom/WriteTo (remove martingale fields)"*

**Should say:** *"Redesign `CStateStore::Save/Load` signatures and `.bin` layout; bump `STATE_MAGIC`."*

**Impact:** Refactor is larger than implied. State persistence will break if not redesigned carefully. Binary format backwards-compatibility strategy is unspecified.

---

### CR3. Quantitative Claims Are Wrong — Affects Impact Estimation

**Status:** 🔴 **CRITICAL FOR PLANNING**

| Metric | PLAN Says | Actual | Delta |
|---|---|---|---|
| Classes to delete | 1 | 1 | ✅ (CMartingaleController) |
| Classes in v10.12 | 13 | **14** | ❌ -1 |
| Classes in v10.13 | 12 | **13** | ❌ -1 |
| `InpMart*` params to remove | ~20 | **11** | ❌ -9 |
| `CMartingaleController` size | ~200 lines | **237 lines** | ❌ -37 |

**Impact:** Teams building estimates off the PLAN will underestimate refactor scope by ~9–18%. Regression-test surface is larger. Effort budgets are wrong.

**Recommendation:** Fix class/param inventory in PLAN before dev work begins. Add a CI step: `grep -c "^class"` and `grep -c "input.*InpMart"` fail on drift.

---

### CR4. Architecture Diagram Contradicts Code

**Status:** 🔴 **DESIGN AMBIGUITY**

Section 3.1 shows `CStateStore` as a **child of `CTradeExecutor`** (composition).

The code has them as **siblings** (separate SECTION 14 and SECTION 15).

**Questions:**
- Is the architecture *intent* composition? If so, refactor should enforce it (move CStateStore inside CTradeExecutor, or justify why they're siblings).
- Does the diagram need updating, or does the code need restructuring?

**Impact:** Ambiguity can lead to inconsistent refactor decisions. Maintainers will be confused about ownership.

**Recommendation:** Either move CStateStore inside CTradeExecutor (composition) or update the diagram to show them as siblings + clarify the dependency.

---

### CR5. No "Minimum Edge" or "Minimum Win Rate" Deployment Gate

**Status:** ⚠️ **RISK ACCEPTANCE UNSPECIFIED**

The PLAN removes martingale (good) but **does not specify: What win rate must the signal engine achieve before deployment?**

Without a backtest or live demo baseline, users are told *"demo test thoroughly"* but given **no quantitative pass/fail criterion.**

**Impact:** Someone deploys with 45% win rate (expecting martingale recovery) and blows up because there is no recovery.

**Recommendation:** Add a section: *"Minimum edge acceptance criteria: Signal must achieve ≥ 55% win rate in walk-forward validation before live deployment. Do not deploy if confidence is < 95%."*

---

### CR6. Dual Execution Path Ordering Is Unspecified

**Status:** ⚠️ **STATE MANAGEMENT RISK**

- Timer path: handles SL enforcement (tick-by-tick)
- Tick path: handles signals

If a tick arrives **during** a timer's `OrderClose` attempt, who wins?

**Plan does not specify.** Risk: a position the timer just closed is then "managed" by a stale tick.

**Impact:** Race condition can cause orphaned orders or stale state.

**Recommendation:** Add explicit conflict-resolution policy, e.g.:
- "On same tick: timer SL always wins (checked first)."
- "Tick signal is only processed if `CountPositions() == 0` on entry."

---

### CR7. "Losing Close" Definition Is Implicit

**Status:** ⚠️ **SPEC AMBIGUITY**

Section 2.4 says *"profit < 0"* — but code's `LastClosedProfit()` includes **swap and commission.**

**Ambiguity:** A trade that closed with positive price-PnL but negative net-PnL (after fees) — is that a "losing close" for the reverse trigger?

**Spec is ambiguous.** Implementation must be source of truth, and spec should match.

**Impact:** Users implementing reverse leg may use wrong definition; reverse fires at wrong times.

**Recommendation:** Update section 2.4: *"'Losing close' is defined as `LastClosedProfit() < 0`, which includes swap and commission. A break-even close (price profit = 0 but swap cost is negative) is a 'losing close' and will trigger the reverse leg."*

---

### CR8. No `.set` File Migration Path for Existing Users

**Status:** ⚠️ **UPGRADE BREAKING**

The PLAN removes all `InpMart*` inputs. Any user with a saved `.set` file will have **orphan keys** after upgrade.

**Plan does not address:** `.set` migration, deprecation warnings, or input-name compatibility shim.

**Impact:** Users upgrade → chart won't load `.set` files → painful re-configuration or silent wrong settings.

**Recommendation:** Either:
1. Provide a `.set` migration script (rename/translate old inputs to new ones)
2. Add `OnInit` deprecation warning: *"Old `.set` file detected; update inputs manually"*
3. Document breaking change in changelog

---

### CR9. Reverse Leg Is a Doubling Strategy in Disguise

**Status:** 🔴 **EXPECTED VALUE ANALYSIS MISSING**

The PLAN's own SWOT (W1) notes the doubling risk but **understates it.**

A clean no-martingale EA has *one* trade per signal. Adding a *second* trade on the same cycle (the reverse) **reintroduces the doubling risk for the *loss path*, just gated behind a different condition** (losing close instead of losing position).

**Expected value analysis:**
- Single trade: `E = p·W − (1−p)·L`
- With reverse: Loss path becomes `−L + p_r·W − (1−p_r)·L = (2p_r − 1)·W − 2(1−p_r)·L`

Reverse *adds* EV only if `p_r > 0.5` *and* `L` is small enough.

**Plan does not analyze this.** Reverse is presented as a feature without mathematical justification.

**Impact:** Users enable reverse without understanding the win-rate requirement for it to be positive-EV.

**Recommendation:** Add a section: *"Reverse Leg Expected Value: The reverse fires only on losing cycles; it is positive-EV only if its own win rate > 50% AND the per-loss size is acceptable. Empirical backtest required before deployment."*

---

### CR10. "FIFO-Compatible" is Asserted But Not Demonstrated

**Status:** ⚠️ **EDGE CASE UNVALIDATED**

Section 2.4 claims: *"Compatible with all account types (hedging and non-hedging / FIFO / netting)"*

This is a **behavioral claim** that needs to be **tested.** With netting accounts, closing the first position and immediately opening the opposite in the same tick can **race with broker-side netting.**

**Edge case:** What if the broker netts the close and open into a single position before our code sees `CountPositions() == 0`?

**Plan does not specify:** FIFO broker test case or netting edge-case handling.

**Impact:** Deployment on wrong broker type could cause position pileup or state corruption.

**Recommendation:** Add to success criteria (section 12): *"FIFO broker test case: Verify that reverse entry opens cleanly on FIFO/netting brokers without broker-side netting interference. Test by running live on micro lot on netting broker for 10 reverse-leg cycles."*

---

## 4. Strategic Recommendations (Prioritized)

| # | Action | Why | Effort | Blocker? |
|---|---|---|---|---|
| **1** | **Bump `STATE_MAGIC` and add version-mismatch refuse-to-load guard** | Stops silent v10.12 state loads (CR1, T9) | XS | ⚠️ Yes |
| **2** | **Rename `InpReverseAfterMin` → `InpReverseAfterLoss`** | Makes semantic change visible to users (CR1) | XS | ⚠️ Yes |
| **3** | **Fix class/param count in PLAN** | Prevents downstream mis-estimation (V3, V4, CR3) | XS | No |
| **4** | **Add walk-forward / backtest gate before declaring success** | Only way to verify 8-condition confluence is actually profitable (W5, CR5, T8) | **M** | ⚠️ Yes |
| **5** | **Add `InpMaxReverseLossesPerDay` and `InpMaxTradesPerDay`** | Bounds doubling risk + respects prop-firm caps (T1, T11, CR9) | **S** | No |
| **6** | **Promote `InpMartMaxADX` to permanent non-mart regime filter** | Reuse existing logic; address choppy-market threat (T4) | **S** | No |
| **7** | **Formally define "losing close" in spec section 2.4** | Close ambiguity around swap/commission (CR7, W12) | XS | No |
| **8** | **Specify timer-vs-tick conflict resolution policy** | Prevent stale-tick state management (CR6, W9) | **S** | No |
| **9** | **Add CI check: PLAN numbers match code** | `grep -c "^class"` and `grep -c "input.*InpMart"` fail on drift (CR3, T10) | **S** | No |
| **10** | **Add FIFO-broker test case to success criteria** | Validate FIFO-compat claim (CR10, O1) | **S** | ⚠️ Yes |
| **11** | **Add `InpMinHoldSec` and `InpMaxRequoteRetries`** | Mitigate broker-ToS and requote risk (T3, T5) | **S** | No |
| **12** | **Provide `.set` migration shim or documented breakage** | Smooth upgrade path (CR8) | **M** | No |
| **13** | **Decide: compose CStateStore into CTradeExecutor or keep sibling?** | Close doc/code drift (CR4, V8, W8) | **S** | No |

**Blockers (must complete before coding phase 1):** 1, 2, 4, 10

---

## 5. Bottom Line

**The PLAN is architecturally sound.** Signal-only, no martingale, FIFO-safe — the right direction.

**But the document is not yet a reliable source of truth:**

1. ✅ **Quantitative claims are wrong** — class count, param count. Fix before estimation.
2. 🔴 **One "new" feature is a silent semantic change** — disclose as breaking change.
3. ⚠️ **Coupling understated** — CStateStore's martingale dependency makes refactor larger.
4. ⚠️ **No edge verification** — 8-condition confluence is a hypothesis, not a measurement.
5. 🔴 **Threats under-covered** — both-leg loss sequences, prop-firm caps, FIFO edge cases, `.set` migration.

**The refactor is the right move. The plan just needs two passes:**
1. **Numeric accuracy** — fix class/param counts, effort estimates, coupling depth.
2. **Completeness** — address the 10 critical findings and 14 threats this review surfaced.

---

## 6. Updated File Structure & Sections

After martingale removal, the final `.mq4` will contain:

```
SECTION 0  — Copyright, property directives, architecture comment block
SECTION 1  — Input parameters (cleaned, ~45 params total, no InpMart*)
SECTION 2  — Constants, structs, utility helpers (PipSize, NormalizeLots, etc.)
SECTION 3  — CSpreadMonitor
SECTION 4  — CRangeScanner
SECTION 5  — CCandleEngine
SECTION 6  — CPpmEngine
SECTION 7  — CVolumeFilter
SECTION 8  — CSessionClock
SECTION 9  — CEquityGuard
SECTION 10 — CRiskModel
SECTION 11 — CVirtualStopManager
SECTION 12 — CTrailingManager
SECTION 13 — CTradeExecutor
SECTION 14 — CStateStore           (formerly Section 15; decide: keep sibling or compose into CTradeExecutor?)
SECTION 15 — CExpertAdvisor        (formerly Section 16; facade, simplified)
SECTION 16 — MT4 event handlers    (delegates to g_ea facade instance)
```

Total sections: **17** (down from 18 by eliminating martingale).

---

## 7. Updated Success Definition

The project is complete when all of the following are confirmed:

- [ ] Compiles cleanly with `#property strict`, zero errors, zero warnings
- [ ] `STATE_MAGIC` bumped; version mismatch check guards against v10.12 state files
- [ ] All `InpMart*` parameters removed — search confirms zero occurrences
- [ ] `CMartingaleController` class deleted — no references anywhere
- [ ] `REENTRY_CONTEXT` struct deleted
- [ ] `ENUM_MART_CONFIRM` enum deleted (or repurposed for reverse-leg filter per O2)
- [ ] `InpReverseAfterMin` renamed to `InpReverseAfterLoss` (or decision documented)
- [ ] "Losing close" formally defined in spec (includes swap+commission)
- [ ] Timer-vs-tick conflict resolution policy specified
- [ ] `ManageEntries()` executes only fresh signal logic
- [ ] `CStateStore` saves/loads only VSL + equity guard + halt state
- [ ] On-chart panel shows clean signal info without martingale fields
- [ ] Reverse-after-losing-close entry fires once per losing cycle, standalone, no hedging requirement
- [ ] State persistence verified across terminal restart
- [ ] Daily drawdown halt and equity floor functional
- [ ] Virtual SL enforcement working (tested in strategy tester)
- [ ] Version string updated to `10.13`
- [ ] All comments consistent with non-martingale design
- [ ] CI check in place: PLAN numbers match code (class count, param count)
- [ ] Walk-forward backtest results show ≥ 55% signal win rate
- [ ] FIFO broker test case passed (10 reverse-leg cycles, no pileup)
- [ ] `.set` migration plan documented or shim provided
- [ ] PLAN.md and README.md updated to reflect v10.13 changes + critical findings

---

## References

- **v10.12 Source:** `oneminuteman.mq4`, 66,756 bytes, 1,785 lines
- **Verification Date:** 2026-07-22
- **Analysis Tool:** Comprehensive source audit + PLAN cross-reference
- **Author:** Mavis (root session)

---

*OneMinuteMan v10.13-no-mart is a disciplined, signal-only M1 scalper. Fixed risk per trade. No recovery. The refactor is sound, but this document must be corrected and completed before development begins.*
