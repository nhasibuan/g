# OneMinuteMan – MT4 M1 Scalping Expert Advisor

> **A production-grade, signal-only, component-based MQL4 Expert Advisor for MetaTrader 4**

## Overview

**OneMinuteMan (OMM)** is a single-file, component-based MQL4 Expert Advisor at **version 10.17**, designed for M1 (1-minute) timeframe scalping. Built by [Norman Hasibuan](https://github.com/nhasibuan) with AI-assisted development, it combines candlestick pattern recognition, a ZigZag-based Pips-Per-Minute (PPM) momentum engine, an **ADX regime filter** (with stateless transition-based chop-hedging), ATR-dynamic risk management, virtual stop-losses, an event-driven loss-reversal system, and a **rolling win-rate performance tracker**.

**v10.17 BUG-FIX & HARDENING:** Five audit findings addressed. **B2 (CRITICAL):** `ManageReverseEntry()` now calls `EquityGuardOK()` — closes a latent bypass where a loss-reversal could fire after `m_vsl.Enforce()` dropped equity below `InpMinEquity` on the same timer tick. **B3 (HIGH):** `ManageBreakoutExit()` wired in `OnTimerHandler` for responsive breakout detection in low-tick environments. **B4 (MEDIUM):** New `InpBreakoutConfirmBars` input (default 1) requires N consecutive directional bars before closing hedge legs, mitigating false-breakout premature closure (T10). **B5:** 8 additional input validations in `OnInit`. **B1:** Fixed stale OMM5 comment in `CStateStore` header.

The EA forcibly operates on M1 candle data regardless of the chart timeframe, enabling focused 1-minute scalping strategy with comprehensive protection.

---

## What This Is

**OneMinuteMan** is a MetaTrader 4 Expert Advisor (EA) written in MQL4, designed for M1 (1‑minute) scalping with **fixed linear risk** and comprehensive risk mitigations. It's a single `.mq4` file, internally organized into **15 single‑responsibility classes** behind a `CExpertAdvisor` facade.

**v10.17:** Bug-fix & hardening release. Critical equity-guard bypass in `ManageReverseEntry()` fixed (B2). Breakout exit wired in timer handler for low-tick environments (B3). New `InpBreakoutConfirmBars` input for false-breakout mitigation (B4). 8 additional input validations (B5). Stale OMM5 comment fixed (B1). Stateless `ChopTransitionTriggered()` predicate retained from v10.16.1. `InpChopRearmBars` and `InpAdxHysteresis` runtime-effective. All 3 position-opening paths now have consistent equity-guard gating.

---

## Core Idea

- **Every 50 ms timer tick**: Samples Ask, updates spread EMA, range, PPM (Pips‑Per‑Minute), and enforces hidden (virtual) stop‑losses.
- **Each new M1 bar (OnTick)**: Recognizes the closed candle's pattern/trend, checks PPM zone and tick‑volume spike, and evaluates entry rules.
- **On losing close**: If enabled, arms a reverse-direction entry after a configurable delay. FIFO/netting compatible — waits for flat account before opening reverse.

---

## Architecture & Design Patterns

The EA is structured as a **single-file component architecture** using classic OOP design patterns within MQL4:

| Pattern | Implementation |
|---|---|
| **Facade** | `CExpertAdvisor` — single entry point delegating all MT4 events |
| **Single Responsibility** | 15 decoupled component classes, each with one clearly-defined purpose |
| **Memento** | `CStateStore` — versioned binary state persistence for crash-safe recovery (OMM6 format) |
| **Guard Clauses** | No hidden global mutation; all state owned by components |

### The 15 Core Components

#### Signal & Market Analysis
- **`CSpreadMonitor`** — Calculates rolling EMA of bid-ask spread; adaptive max-spread & slippage multipliers (symbol-agnostic)
- **`CRangeScanner`** — Ring-buffer of tick High/Low samples over 60-second window (1,200 samples @ 50ms intervals)
- **`CCandleEngine`** — Classifies 11 candlestick types (Hammer, Marubozu, 3 Doji variants, Long/Short, Spinning Top, Inverted Hammer) and derives trend direction vs SMA
- **`CPpmEngine`** — Uses ZigZag indicator to compute pips-per-minute efficiency; classifies zones as LOW / MEDIUM / HIGH
- **`CVolumeFilter`** — Tick-volume spike gate; blocks entries when volume is below threshold to ensure liquidity confirmation
- **`CAdxFilter`** _(v10.14/v10.15/v10.17)_ — ADX trend-strength regime filter: blocks fresh entries in choppy markets (v10.14), optionally opens mean-reversion range-fade positions in chop via `InpEnableChopHedge` (v10.15), supports a stateless transition trigger `ChopTransitionTriggered()` that fires only on trend→chop crossing (v10.16.1 fix), breakout exit with configurable confirmation window `InpBreakoutConfirmBars` (v10.17 B4)

#### Session, Risk & Performance
- **`CSessionClock`** — Timezone-aware session window; daily halt flag persists across restarts
- **`CEquityGuard`** — Dual protection: max daily drawdown % and absolute equity floor; evaluated every tick; can auto-flatten on breach
- **`CRiskModel`** — ATR-dynamic SL/TP/trailing/break-even with manual pip overrides and minimum risk floor
- **`CPerformanceTracker`** _(v10.14)_ — Rolling win-rate over last N trades; optional auto-halt below threshold; writes per-trade CSV log

#### Protection & Execution
- **`CVirtualStopManager`** — Hidden SL registry with retry logic; sends wide broker "safety SL" for disconnect protection
- **`CTrailingManager`** — Break-even promotion and ATR-based trailing stop management
- **`CTradeExecutor`** — `OrderSend` with dynamic params; emergency flatten; closed-profit scanning; ensures max 1 open position per symbol
- **`CStateStore`** — Versioned binary save/load using Memento pattern (OMM6 format); survives terminal crash without losing state

---

## Key Components Deep Dive

### Signal Logic (Entry Conditions)

**All conditions must be true for a fresh entry (12-AND conjunctive gate):**

1. Trading enabled (`InpEnableTrading = true`)
2. No open position on the symbol (single-position invariant)
3. Inside session hours
4. Spread within adaptive limit
5. Equity guard passes (min equity + drawdown check)
6. No reversal pending (reversal takes priority over fresh entry)
7. Daily trade limit not reached (`InpMaxTradesPerDay`)
8. New bar + candle data valid + PPM data valid
9. PPM zone is MEDIUM or HIGH (ZigZag momentum confirmed)
10. Tick volume ≥ multiplier × average (liquidity spike confirmed)
11. Candle produces a directional signal (pattern + trend aligned)
12. ADX ≥ threshold for fresh trend entries; chop-hedge uses the opposite closed-bar transition (`ADX[2] >= threshold` → `ADX[1] < threshold`) when `InpEnableChopHedge=true`

> [!WARNING]
> **`InpEnableChopHedge = true` (v10.15+):** Allows multiple concurrent positions (up to `InpMaxHedgeLegs`). This **breaks the single-position invariant and FIFO compatibility**. v10.16 default trigger is **TRANSITION** (fires once per regime switch). `InpBreakoutExit = true` (default) closes hedge legs on breakout. **Do not enable on FTMO/prop-firm accounts or US/EU netting brokers.**

### Loss-Reversal Engine (v10.13)

The EA can optionally open a reverse-direction position **after a losing close**:

- Enabled by `InpEnableLossReversal` (default **`true`**).
- **Trigger**: When a position closes with `LastClosedProfit() < 0` (including swap + commission), the reverse leg is armed.
- **Delay**: Waits `InpLossReversalDelaySec` seconds (default **5**) after the losing close before opening the reverse.
- **FIFO/netting compatible**: Waits for `CountPositions() == 0` (flat account) before opening. No concurrent hedging.
- **Direction**: Always opposite to the losing position's direction.
- **Lot size**: `InpReverseLots` when `> 0`, otherwise `InpBaseLots`.
- **Confirmation gate**: Configurable via `InpReverseConfirm` (NONE / CANDLE / PPM / EITHER / BOTH).
- **Daily limits**: `InpMaxReverseLossesPerDay` (default 3) caps reverse-leg losses per day. `InpMaxTradesPerDay` caps total trades.
- Fires only **once per losing cycle**: if the reverse also loses and limits permit, another reverse is armed.

> ℹ️ **"Losing close" is formally defined as `LastClosedProfit() < 0`, which includes swap and commission. A break-even close with negative swap cost is a losing close and will trigger the reverse leg.**

> ⚠️ **This is NOT a martingale.** Lot size is always `InpBaseLots` (or `InpReverseLots`). There is no multiplier, no step ladder, no compounding. Each reverse trade risks the same fixed amount.

### Execution & State Persistence

- **Adaptive Execution**: Spread/slippage derived from rolling EMA multipliers; symbol-agnostic (no hardcoded pair profiles)
- **State Persistence**: Saves on every trade/halt/deinit; restores on init; survives restart, chart re-attach, VPS migration, and recompilation safely
- **Versioned Format**: `CStateStore` uses magic tag `OMM5` (0x4F4D4D35) to safely discard incompatible state files from older versions (including OMM4 from v10.12)

### Conflict Resolution Policy (Timer vs. Tick)

- **Timer path** handles SL enforcement (tick-by-tick via `CVirtualStopManager`) and trailing stop management
- **Tick path** handles signal evaluation and trade state tracking
- **Policy**: Timer SL enforcement always executes first. Both paths guard order actions with `CountPositions()` checks. If a timer closes a position, the tick path's `UpdateTradeState()` detects it safely.

---

## Comprehensive Risk & Protection System

| Guard | Mechanism | Purpose |
|---|---|---|
| **Virtual SL** | Hidden from broker; enforced tick-by-tick with retry on failure | Tight, adaptive risk control |
| **Safety SL** | Wide real SL sent to broker (default 5× virtual) | Disconnect insurance |
| **Break-even** | Promotes SL to open price + lock pips once profit triggers | Eliminates downside tail risk |
| **Trailing stop** | Tightens virtual SL once profit ≥ configured start level | Captures trending moves |
| **Daily drawdown** | Halts all trading after specified daily % loss; force-flattens on breach | Session-level loss cap |
| **Equity floor** | Absolute minimum equity halt threshold | Account-level loss cap |
| **Daily trade cap** | Optional `InpMaxTradesPerDay` limits total trades per day | Prevents overtrading |
| **Reverse loss cap** | `InpMaxReverseLossesPerDay` limits reverse-leg losses per day | Contains doubling risk |
| **Reverse confirmation** | Candle/PPM signal confirmation gate for reverse entries | Filters low-quality reversals |
| **State persistence** | Binary Memento with day-stamped baseline and halt flag (OMM5) | Crash-safe protection state |

---

## Comprehensive SWOT Analysis (v10.13)

### Strengths (14 Items)

| ID | Strength | Evidence |
|---|---|---|
| **S1** | **Fixed linear risk per trade** | `InpBaseLots` is the only lot source; no compounding. Worst-case per-trade loss is enumerable. |
| **S2** | **Hard-bounded daily drawdown** | `CEquityGuard` combines daily-DD% halt + absolute equity floor; persistent across restarts. |
| **S3** | **Crash-safe state (OMM5)** | Versioned binary file with magic tag verification. Old OMM4 files safely discarded. |
| **S4** | **Two-layer stop loss** | Virtual SL + wide broker safety SL (5×) — two independent protection paths. |
| **S5** | **Single-position invariant** | `CountPositions()` + emergency-flatten clause; structural, not procedural. |
| **S6** | **Deterministic, no RNG** | No `MathRand` anywhere; backtests are 100% reproducible. |
| **S7** | **8-AND conjunctive signal gate** | High specificity entry filter; low false-signal rate. |
| **S8** | **Session-aware timezone** | `CSessionClock` with explicit TZ offset avoids DST bugs. |
| **S9** | **FIFO/netting compatible** | Reverse leg waits for flat account; zero concurrent hedging. |
| **S10** | **ATR-adaptive risk** | SL/TP/trail/BE scale with market volatility automatically. |
| **S11** | **Clean SRP decomposition** | 13 classes, each with one named responsibility; easy to swap components. |
| **S12** | **No DLL, no external lib** | Pure single-file MQL4; one file deployment. |
| **S13** | **Reversal confirmation gate** | `ENUM_REVERSE_CONFIRM` filters reverse entries by candle/PPM signals. |
| **S14** | **Daily limits on reversals** | `InpMaxReverseLossesPerDay` and `InpMaxTradesPerDay` bound worst-case exposure. |

### Weaknesses (12 Items)

| ID | Weakness | Impact |
|---|---|---|
| **W1** | **Reverse leg can compound losses** | Consecutive both-leg losses (original + reverse) = 2× per-cycle drawdown. |
| **W2** | **No recovery mechanism by design** | If signal win rate < 50% with R:R ≤ 1, expected value is negative. |
| **W3** | **ZigZag repaint on incomplete bars** | `m_ppm_valid` flag mitigates but look-ahead bias risk exists in backtesting. |
| **W4** | **Single-file MQL4 size ceiling** | ~1500 lines; future features may force refactor to `.mqh` includes. |
| **W5** | **No backtest evidence shipped** | Signal quality unverified at release time; users must validate independently. |
| **W6** | **No formal minimum win rate gate** | Plan does not specify what win rate must be achieved before deployment. |
| **W7** | **Dual execution path (timer + tick)** | Explicit conflict-resolution policy added, but edge cases may exist. |
| **W8** | **No `.set` file migration** | Users upgrading from v10.12 must reconfigure inputs manually. |
| **W9** | **Unquantified conjunction frequency** | 8-AND filter may over-filter in low-volatility or under-filter in trending regimes. |
| **W10** | **"Losing close" includes swap/commission** | Trades with positive price P&L but negative net P&L trigger reverse. |
| **W11** | **Single maintainer** | Bus factor = 1; no external CI/CD or issue tracker. |
| **W12** | **No multi-symbol coordination** | Each chart instance operates independently; shared risk across symbols not managed. |

### Opportunities (11 Items)

| ID | Opportunity | Realizability |
|---|---|---|
| **O1** | **Prop-firm / funded-account market** | High — Conservative profile matches prop-firm requirements exactly. |
| **O2** | **Walk-forward / Monte-Carlo verification** | High — Deterministic engine enables automated pipeline. |
| **O3** | **A/B reverse-leg on/off testing** | High — `InpEnableLossReversal = false` provides clean baseline. |
| **O4** | **Per-session parameter profiles** | Medium — ATR/PPM thresholds per session (London/NY). |
| **O5** | **Mean-reversion capture** | Medium — Reverse-after-loss is a structural mean-reversion bet. |
| **O6** | **Telemetry export (CSV/JSON trade log)** | Medium — Optional `FileWrite` per trade for analysis. |
| **O7** | **MQL5 port** | Medium — Architecture is language-agnostic; doubles addressable market. |
| **O8** | **Open-source credibility** | Medium — No martingale = trust signal for disciplined traders. |
| **O9** | **ADX regime filter (permanent)** | High — Add non-martingale ADX filter to block entries in choppy markets. |
| **O10** | **Configurable reverse delay as noise filter** | High — Post-loss delay skips initial volatility spike. |
| **O11** | **Multi-symbol manager EA** | Medium — Component isolation supports multi-instance coordination. |

### Threats (9 Items)

| ID | Threat | Severity | Mitigation |
|---|---|---|---|
| **T1** | **Both-leg loss sequences** | High | `InpMaxReverseLossesPerDay` bounds daily reverse losses. |
| **T2** | **Spread-spike on M1 during news** | High | `CSpreadMonitor` gates entry; add post-news grace period. |
| **T3** | **Broker requotes / latency** | High | Adaptive slippage; add `InpMaxRequoteRetries` in future. |
| **T4** | **Ranging/choppy markets** | High | Add permanent ADX regime filter (opportunity O9). |
| **T5** | **Regulatory / ToS restrictions** | Medium | `InpMinHoldSec` input supports broker minimum hold rules. |
| **T6** | **ZigZag repaint contaminating signals** | Medium | Enforced on closed bars via `m_ppm_valid`. |
| **T7** | **Overfitting to historical data** | Medium | Walk-forward validation required before live deployment. |
| **T8** | **MQL4 compiler deprecation** | Low | MQL5 port addresses long-term platform risk. |
| **T9** | **Single-file git merge conflicts** | Low | Refactor to `.mqh` includes if team grows. |

---

## Design Review

### Architecture & Code Quality

- **Clean Component Boundary**: Facade + 13 SRP classes with explicit wiring; MT4 handlers only delegate; no global mutable state
- **Well-Documented Flows**: Architecture comment block describes all components and their responsibilities
- **Robustness**: Versioned state files (magic tag `OMM5` = 0x4F4D4D35), day-stamped drawdown baseline, retry on virtual SL close failures
- **Performance Note**: `CRangeScanner::Rescan()` performs O(n) scan on every tick with 1,200-sample window. Min-max deque would be O(1) amortized if performance becomes a concern

### Risk Management Maturity

- EA explicitly uses fixed linear risk with no compounding
- **Multiple Overlapping Guards**: Daily drawdown, minimum equity, daily trade cap, reverse loss cap, confirmation gates
- Clean separation between signal-driven fresh entries and event-driven loss-reversal entries

### Observability

- **On-Chart Panel**: Shows range/candle, PPM/zone, spread vs adaptive limit, loss-reversal status (pending/armed, direction, delay countdown), daily trade count, reversal loss count, halt status
- **Experts Log**: Detailed event logging for every loss-reversal arm/fire/skip, state recovery on init

### Breaking Changes from v10.12

| Change | Details |
|---|---|
| **`InpReverseAfterMin` removed** | Replaced by `InpEnableLossReversal` — different semantics (event-driven on loss, not time-based) |
| **All `InpMart*` inputs removed** | 15 martingale inputs deleted; users must reconfigure `.set` files |
| **`CMartingaleController` deleted** | 237 lines of martingale logic removed |
| **`STATE_MAGIC` bumped to OMM5** | Old OMM4 state files safely discarded on load |
| **`REENTRY_CONTEXT` struct deleted** | Martingale re-entry context no longer needed |
| **New inputs added** | `InpLossReversalDelaySec`, `InpReverseConfirm`, `InpMaxReverseLossesPerDay`, `InpMaxTradesPerDay`, `InpMinHoldSec` |

---

## Getting Started

### Pre-Flight Checklist

#### 1. **Compile**
```
1. Copy oneminuteman.mq4 to MQL4/Experts folder
2. Open MetaEditor and compile the file
3. Verify ZigZag indicator is present on your terminal
   (OnInit will verify and return INIT_FAILED if missing)
```

#### 2. **Observe First (Demo Mode)**
```
1. Attach to an M1 chart with InpEnableTrading=false
2. Monitor the on-chart panel for 1-2 hours:
   - Spread vs adaptive limit
   - PPM zone classification
   - Candle pattern recognition
   - Reversal status (armed/pending/idle)
   - Trade count and reversal loss count
3. Review Experts log for any warnings or errors
```

#### 3. **Demo Validation (2–4 weeks)**
```
1. Enable trading on demo: InpEnableTrading = true
2. Use conservative risk profile:
   - InpMaxDrawdownPct = 2.0
   - InpMinEquity = 1000
   - InpMaxReverseLossesPerDay = 2
   - InpMaxTradesPerDay = 10
3. Monitor:
   - Daily drawdown curve
   - Loss-reversal firing behavior
   - Equity guard triggers
   - Signal win rate (should be >= 55% for positive EV)
4. Only after 2–4 weeks of stable demo results consider live with 1/10th position size
```

---

## Input Parameters

| Input | Default | Purpose |
|---|---|---|
| `InpEnableTrading` | `false` | Master kill switch — EA observes but does not trade when false |
| `InpBaseLots` | `0.01` | Base lot size for fresh entries and reverse leg (when `InpReverseLots = 0`) |
| `InpSlippage` | `0` | Order slippage in points; `0` = auto-derived from spread EMA |
| `InpMaxSpread` | `0` | Max allowed spread in points; `0` = auto-derived from spread EMA |
| `InpMagic` | `100` | EA magic number — must be unique per chart/symbol |
| `InpTP_Pips` | `0` | Take-profit in pips; `0` = ATR-dynamic |
| `InpSL_Pips` | `0` | Stop-loss in pips; `0` = ATR-dynamic |
| `InpHideSL` | `true` | Use virtual (hidden) SL instead of broker SL |
| `InpUseSafetySL` | `true` | Send wide real SL to broker as disconnect safety net |
| `InpSafetySLMult` | `5.0` | Safety SL distance = virtual SL × this multiplier |
| `InpAtrPeriod` | `14` | ATR period for dynamic risk calculations |
| `InpAtrSLMult` | `1.5` | SL = ATR × this multiplier |
| `InpAtrTPMult` | `2.0` | TP = ATR × this multiplier |
| `InpMinRiskPips` | `1.0` | Minimum floor for any ATR-derived pip distance |
| `InpMaxDrawdownPct` | `10.0` | Halt trading if daily drawdown ≥ this percentage |
| `InpMinEquity` | `100.0` | Halt trading if account equity falls below this value |
| `InpCloseOnGuardBreach` | `true` | Force-close all positions when equity guard triggers |
| `InpEnableLossReversal` | `true` | Enable event-driven reverse-after-losing-close |
| `InpLossReversalDelaySec` | `5` | Seconds to wait after losing close before reverse entry |
| `InpReverseLots` | `0.0` | Lot size for reverse leg; `0` = use `InpBaseLots` |
| `InpReverseConfirm` | `REVERSE_CONFIRM_NONE` | Signal confirmation for reverse entry (NONE/CANDLE/PPM/EITHER/BOTH) |
| `InpMaxReverseLossesPerDay` | `3` | Max reverse-leg losses per day; `0` = unlimited |
| `InpMaxTradesPerDay` | `0` | Max total trades per day; `0` = unlimited |
| `InpMinHoldSec` | `0` | Minimum seconds to hold before closing; `0` = off |
| `InpAverPeriod` | `14` | SMA period for candle body average and trend classification |
| `InpSampleMs` | `50` | Timer interval (ms) for tick-rate range sampling |
| `InpWindowSize` | `1200` | Ring-buffer size for range scanner (1200 × 50ms = 60s window) |
| `InpUseVolumeFilter` | `true` | Enable tick-volume spike gate for fresh entries |
| `InpVolLookback` | `20` | Bars to average for volume filter baseline |
| `InpVolMultiplier` | `1.5` | Volume must be ≥ average × this multiplier to pass |
| `InpTzOffsetHours` | `7` | Local timezone offset from GMT (e.g., WIB = +7) |
| `InpSessionStartHour` | `5` | Session open hour (local time) |
| `InpSessionEndHour` | `24` | Session close hour (local time) |
| **v10.14 — ADX Regime Filter** | | |
| `InpUseAdxFilter` | `true` | Enable ADX trend-strength gate; blocks entry in choppy markets |
| `InpAdxPeriod` | `14` | ADX indicator period |
| `InpAdxThreshold` | `20.0` | Minimum ADX value for a fresh entry to be allowed |
| **v10.14 — Performance Tracker & Win-Rate Halt** | | |
| `InpUseWinRateHalt` | `false` | Halt trading if rolling win-rate falls below `InpMinWinRate` |
| `InpWinRateWindow` | `20` | Number of trades in the rolling win-rate window |
| `InpMinWinRate` | `0.45` | Minimum acceptable win-rate; auto-halt if below (requires full window) |
| **v10.14 — Reversal Safety** | | |
| `InpReversalArmTimeoutSec` | `300` | Auto-disarm reversal if not fired within N seconds; `0` = off |
| **v10.15/v10.16.1 — Chop-Hedging Engine** | | |
| `InpEnableChopHedge` | `false` | **Enable chop-hedging (FIFO-BREAKING; default OFF).** Opens mean-reversion position when `ADX < InpAdxThreshold`. Requires `InpUseAdxFilter=true`. |
| `InpChopHedgeTrigger` | `TRANSITION` | **Trigger mode**: `STATE` fires every choppy bar (v10.15 behavior); `TRANSITION` fires only on the trend→chop edge via stateless `ChopTransitionTriggered()` (v10.16.1 fix). |
| `InpChopRearmBars` | `1` | Number of consecutive trend bars required before a new trigger can fire. Higher = stricter confirmation. |
| `InpAdxHysteresis` | `0.0` | Dead zone around threshold: enter chop at `thr−hyst`, exit at `thr+hyst`. `0` = exact threshold. |
| `InpHedgeLots` | `0.0` | Lot size for hedge legs; `0.0` = use `InpBaseLots` |
| `InpMaxHedgeLegs` | `2` | Maximum concurrent chop-hedge legs (hard exposure cap) |
| `InpBreakoutExit` | `true` | Close all hedge legs when ADX returns to directional (breakout detection, TH2 mitigation) |

---

## Preset Profiles (`.set` Files)

Two preset files are shipped with the EA. Load them via MT4 Strategy Tester → Settings → Load or the EA property dialog → Load.

| File | Use Case | Key Settings |
|---|---|---|
| `conservative.set` | Personal accounts, initial demo testing | Lots=0.01, DD=5%, Trades=5/day, ADX=ON, ChopHedge=OFF |
| `ftmo_challenge.set` | FTMO/MFF/The5ers challenge accounts | Lots=0.01, DD=4%, Trades=3/day, ADX=ON, WinRateHalt=ON, ChopHedge=OFF |

> [!IMPORTANT]
> Both presets ship with `InpEnableTrading=false` and `InpEnableChopHedge=false`. Enable trading only after demo-validating on your broker. **Never enable `InpEnableChopHedge` on prop-firm or FIFO/netting accounts.** When enabled, the default TRANSITION trigger mode is recommended.

## Overall Assessment

**OneMinuteMan v10.16.1** is a technically sophisticated, well-documented MT4 scalping EA with fixed linear risk, comprehensive persistent risk controls, and a clean signal-only architecture. v10.16.1 fixes a **critical runtime defect**: the v10.16 TRANSITION chop-hedge trigger was always-false due to a same-tick ADX read in the state machine. The fix replaces the broken state machine with a **stateless closed-bar predicate** `ChopTransitionTriggered()`, activates `InpChopRearmBars`/`InpAdxHysteresis`, and deletes the dead code. Breakout exit (TH2) remains functional.

See PLAN.md v10.16.1 section for full root cause analysis, truth table, and SWOT.

### Summary

| Aspect | Rating | Notes |
|---|---|---|
| **Architecture** | ⭐⭐⭐⭐⭐ | Clean OOP, 15 SRP components, zero globals |
| **Risk Management** | ⭐⭐⭐⭐⭐ | Fixed risk, daily caps, persistent state, ATR-adaptive |
| **Code Quality** | ⭐⭐⭐⭐⭐ | Bug-fix documentation, guard clauses, input validation |
| **Documentation** | ⭐⭐⭐⭐ | Clear README, comprehensive SWOT, preset profiles, but no official backtest results |
| **Backtesting** | ⭐⭐ | No walk-forward results provided |
| **FIFO Compatibility** | ⭐⭐⭐⭐ | Designed for FIFO/netting; needs live broker validation |
| **Chop-Hedge** | ⭐⭐⭐⭐ | Stateless transition trigger (v10.16.1 fix), breakout exit, but no backtest evidence |

### Primary Caveats

1. **Signal Win Rate Required**: Without martingale recovery, the signal must achieve ≥ 55% win rate (or favorable R:R ratio) for positive expected value
2. **Independent Validation Required**: You must perform your own backtests and demo validation before any live use
3. **No Official Backtest Statistics**: Trust in the EA's edge must rest on your own testing and code/design quality
4. **Reverse Leg Risk**: Both-leg losses (original + reverse) double per-cycle drawdown; `InpMaxReverseLossesPerDay` mitigates but does not eliminate this risk
5. **Breaking Change from v10.12**: All martingale inputs removed; `.set` files must be recreated; state files are incompatible (OMM4 → OMM5)
6. **Chop-Hedge Risk (v10.15+)**: When `InpEnableChopHedge=true`, multiple concurrent positions are opened. This breaks FIFO/netting compatibility and the fixed-linear-risk guarantee. Maximum exposure = `InpMaxHedgeLegs × InpHedgeLots`. Do not enable on prop-firm or netting broker accounts.
7. **v10.16 TRANSITION Bug (Fixed in v10.16.1)**: The v10.16 state machine (`JustBecameChoppy` + `UpdateRegime`) was always-false. If you used v10.16 with TRANSITION mode, chop-hedging silently never fired. Upgrade to v10.16.1.
8. **False Breakout Risk**: `InpBreakoutExit=true` closes hedge legs when ADX spikes above threshold. A 1-bar false breakout can close legs prematurely.

### Recommendation

✅ **Demo test thoroughly** (2–4 weeks minimum) before live deployment.

✅ **Start with conservative risk profile** (2% daily drawdown, max 3 reverse losses/day).

✅ **Monitor on-chart panel and Experts log** to understand entry signals and reversal behavior.

✅ **Verify signal win rate ≥ 55%** before enabling loss-reversal or going live.

✅ **This is a disciplined, signal-only system** suitable for experienced traders who value fixed risk and clean execution.

---

## Resources

- **Repository**: [nhasibuan/g](https://github.com/nhasibuan/g)
- **Author**: [Norman Hasibuan (@nhasibuan)](https://github.com/nhasibuan)
- **Latest Version**: v10.17 (July 30, 2026) — **bug-fix & hardening**: B2 critical equity-guard bypass fix in `ManageReverseEntry()`, B3 timer breakout exit wiring, B4 `InpBreakoutConfirmBars` for false-breakout mitigation, B5 8 additional input validations, B1 stale OMM5 comment fix
- **License**: [MIT](LICENSE)
- **Contributing**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **For Issues/Questions**: Refer to repository documentation and risk warnings

---

*OneMinuteMan v10.17 is a disciplined, signal-only M1 scalper with 5 audit findings fixed (1 critical equity-guard bypass, 1 high timer coverage gap, 1 medium false-breakout mitigation, 1 low stale comment, 1 low input validation). Fixed risk per trade. No martingale. No compounding. 65 configurable inputs. 15 SRP classes. 12 serial entry guards. All 3 position-opening paths have consistent equity-guard gating. Stateless chop-hedge trigger (TRANSITION default, STATE available). Breakout exit with configurable confirmation window. Demo thoroughly and trade responsibly.*
