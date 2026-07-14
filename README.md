# OneMinuteMan – MT4 M1 Scalping Expert Advisor

> **A production-grade, component-based MQL4 Expert Advisor for MetaTrader 4**

## Overview

**OneMinuteMan (OMM)** is a single-file, component-based MQL4 Expert Advisor at **version 10.12**, designed for M1 (1-minute) timeframe scalping. Built by [Norman Hasibuan](https://github.com/nhasibuan) with AI-assisted development, it combines candlestick pattern recognition, a ZigZag-based Pips-Per-Minute (PPM) momentum engine, ATR-dynamic risk management, virtual stop-losses, and a multi-layered martingale recovery system.

The EA forcibly operates on M1 candle data regardless of the chart timeframe, enabling focused 1-minute scalping strategy with comprehensive protection.

---

## What This Is

**OneMinuteMan** is a MetaTrader 4 Expert Advisor (EA) written in MQL4, designed for M1 (1‑minute) scalping with a martingale recovery layer and comprehensive risk mitigations. It's a single `.mq4` file, internally organized into 13 single‑responsibility classes behind a `CExpertAdvisor` facade, and it's heavily documented with PRD, architecture diagrams, data dictionary, user guide, inputs, changelog, and risk warnings.

---

## Core Idea

- **Every 50 ms timer tick**: Samples Ask, updates spread EMA, range, PPM (Pips‑Per‑Minute), and enforces hidden (virtual) stop‑losses.
- **Each new M1 bar (OnTick)**: Recognizes the closed candle's pattern/trend, checks PPM zone and tick‑volume spike, evaluates entry/martingale rules, and persists protection state so restarts don't bypass safety mechanisms.

---

## Architecture & Design Patterns

The EA is structured as a **single-file component architecture** using classic OOP design patterns within MQL4:

| Pattern | Implementation |
|---|---|
| **Facade** | `CExpertAdvisor` — single entry point delegating all MT4 events |
| **Single Responsibility** | 13 decoupled component classes, each with one clearly-defined purpose |
| **State Machine** | `CMartingaleController` — centralized re-entry decision gate |
| **Memento** | `CStateStore` — versioned binary state persistence for crash-safe recovery |
| **Guard Clauses** | No hidden global mutation; all state owned by components |

### The 13 Core Components

#### Signal & Market Analysis
- **`CSpreadMonitor`** — Calculates rolling EMA of bid-ask spread; adaptive max-spread & slippage multipliers (symbol-agnostic)
- **`CRangeScanner`** — Ring-buffer of tick High/Low samples over 60-second window (1,200 samples @ 50ms intervals)
- **`CCandleEngine`** — Classifies 10 candlestick types (Hammer, Marubozu, Doji variants, Long/Short, Spinning Top, Inverted Hammer) and derives trend direction vs SMA
- **`CPpmEngine`** — Uses ZigZag indicator to compute pips-per-minute efficiency; classifies zones as LOW / MEDIUM / HIGH
- **`CVolumeFilter`** — Tick-volume spike gate; blocks entries when volume is below threshold to ensure liquidity confirmation

#### Session & Risk Management
- **`CSessionClock`** — Timezone-aware session window; daily halt flag persists across restarts
- **`CEquityGuard`** — Dual protection: max daily drawdown % and absolute equity floor; evaluated every tick; can auto-flatten on breach
- **`CRiskModel`** — ATR-dynamic SL/TP/trailing/break-even with manual pip overrides and minimum risk floor

#### Protection & Execution
- **`CVirtualStopManager`** — Hidden SL registry with retry logic; sends wide broker "safety SL" for disconnect protection
- **`CTrailingManager`** — Break-even promotion and ATR-based trailing stop management
- **`CMartingaleController`** — Centralized re-entry decision point with 7-layer protection gates and state machine
- **`CTradeExecutor`** — `OrderSend` with dynamic params; emergency flatten; closed-profit scanning; ensures max 1 open position per symbol
- **`CStateStore`** — Versioned binary save/load using Memento pattern; survives terminal crash without losing state

---

## Key Components Deep Dive

### Signal Logic (Entry Conditions)

**All conditions must be true for a fresh entry:**

1. Trading enabled (`InpEnableTrading = true`)
2. No open position on the symbol
3. Inside session hours
4. Spread within adaptive limit
5. Equity guard passes (min equity + drawdown check)
6. PPM zone is MEDIUM or HIGH (ZigZag momentum confirmed)
7. Tick volume ≥ multiplier × average (liquidity spike confirmed)
8. Candle produces a directional signal (pattern + trend aligned)

### Martingale Design (v10.10–v10.12)

All re-entry decisions pass through a **single centralized decision gate** `CMartingaleController::ReentryAllowed()`, evaluated in order of cost:

**7-Layer Protection Gates:**

1. **Consecutive-loss pause** — Blocks re-entry after `InpMaxConsecLosses` (default 3) consecutive losses
2. **ATR-adaptive step cap** — Fewer steps allowed at high volatility; fewer steps = fewer compounding risks
3. **Progressive cooldown** — Enforces bar delays between steps; schedule is configurable (e.g., `"0,1,2,3,5"` bars)
4. **Same-bar ATR price-spacing floor** — Price must move ≥ `InpMartMinAtrDist × ATR` before re-entry allowed (prevents stacking on same price)
5. **ADX trend gate** — Blocks the reverse re-entry when ADX is weak (only reverse when a confirmed trend exists)
6. **Reversal confirmation** — Configurable: NONE / CANDLE / PPM / EITHER / BOTH
7. **Decaying multiplier schedule** — Optional lot size decay (e.g., `"2.0,1.8,1.6,1.4,1.2"`) to reduce worst-case drawdown

**Direction:**
- Re-entries are always **reverse-direction** — each re-entry opens in the opposite direction of the prior (closed) position to exploit mean reversion. The former `MART_SAME_DIRECTION` / `MART_REVERSE_DIRECTION` enum (`ENUM_MART_MODE`) and the `InpMartMode` input have been **removed** in v10.12. The only behaviour is now reverse-direction.

**State Machine:**
- Tracks step number, direction, loss streak, cooldown countdown, halt flag, and cycle completion
- Halt persists across session boundaries and terminal restarts

### Time-Based Reverse Entry

Independent of the martingale recovery path, the EA can open a single opposite-direction position a fixed time after the **first** position opens:

- Enabled by `InpReverseAfterMin` (default **`true`**).
- **`InpReverseDelaySec`** seconds (default **60** — one minute) after the first entry fills, the EA opens a position in the **opposite** direction.
- It does **not** wait for the first position to close and does **not** go through any martingale re-entry gates. It uses `MART_CONFIRM_NONE` semantics: no candle / PPM / ADX / ATR / cooldown gates — it opens immediately once the delay has elapsed.
- Lot size is `InpReverseLots` when `> 0`, otherwise `InpBaseLots`.
- Fires only **once per cycle**: the guard resets when the account goes flat (no open positions), so the next fresh entry starts a new reverse timer.
- Runs on both `OnTick` and the millisecond `OnTimer` for sub-second precision, outside the fresh/martingale entry gating (which early-returns while any position is open).

> ⚠️ **Requires a HEDGING-capable broker.** On FIFO / netting accounts the opposite order will net against or close the first position instead of running as a second independent leg.

### Execution & State Persistence

- **Adaptive Execution**: Spread/slippage derived from rolling EMA multipliers; symbol-agnostic (no hardcoded pair profiles)
- **State Persistence**: Saves on every trade/halt/deinit; restores on init; survives restart, chart re-attach, VPS migration, and recompilation safely
- **Versioned Format**: `CStateStore` uses magic tag `OMM4` (0x4F4D4D34) to safely discard incompatible state files from older versions

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
| **Consecutive-loss pause** | Blocks re-entries after N consecutive losses | Streak deceleration |
| **State persistence** | Binary Memento with day-stamped baseline and halt flag | Crash-safe protection state |

---

## Auto-Calibration (v10.11)

When `InpAutoCalibrateMartAtr = true`, the EA on initialization:

- Samples the last 500 M1 bars
- Derives ATR thresholds using percentile statistics:
  - **50th percentile** → low-volatility PPM threshold
  - **85th percentile** → high-volatility PPM threshold
- **Suggests** (but does not auto-apply) ADX threshold in the Experts log
- Logs: `Auto-calibrate: lowPips=X, highPips=Y, adxSuggest=Z`

**Design note**: Thresholds are *suggested*, not auto-applied. This prevents overfitting to recent volatility and requires users to validate on demo first—a responsible safeguard against regime-shift drawdowns.

---

## SWOT Analysis

### Strengths

✅ **Exceptional Code Discipline for MQL4**
- Full OOP with named design patterns (Facade, Memento, Strategy, Guard Clauses)
- Zero hidden globals; all state owned by components
- No god objects; clear single responsibility

✅ **Defense-in-Depth Risk Model**
- 7-layer martingale gate + virtual SL + safety SL + equity guard + daily halt
- Each layer independently effective; multiple failures required to breach

✅ **Persistent State Across Restarts**
- Survives terminal crash/restart without losing martingale step or halt state
- Critical for live trading; prevents bypassing safety on recompile

✅ **ATR-Adaptive Everything**
- SL, TP, trailing, step counts, cooldown all scale dynamically to volatility
- No hardcoded breakpoints; works on scalps, micro-lots, and different pairs

✅ **Highly Configurable**
- Progressive schedules (cooldown, multiplier decay)
- Mode-aware ADX, reversal confirmation enums
- Suitable for conservative to aggressive profiles

✅ **Active, Transparent Development**
- 7+ PRs, daily commits, clean commit messages
- Devin AI-assisted with human oversight
- Bug fixes documented with `// FIX-N:` comments explaining original defect and resolution

### Weaknesses

❌ **Inherent Martingale Risk**
- Even with 7-layer protection, consecutive losing streaks in trending markets can produce large drawdowns
- Safeguards *reduce* risk but do not *eliminate* blow-up risk
- Worst-case cumulative exposure at fixed multiplier is exponential in step count

❌ **Single-File Architecture Limit**
- 64KB source is already large; adding more components will stress maintainability in MQL4's single-file constraint
- Cannot easily split into libraries or modules

❌ **ZigZag Dependency**
- `CPpmEngine` relies on built-in ZigZag indicator; missing or version mismatch causes `INIT_FAILED`
- No fallback if ZigZag behaves unexpectedly on exotic pairs

❌ **M1 Forced Operation**
- Tick-frequency EMA and ring buffer scanning is computationally intensive
- Performance on slow VPS environments not documented
- May face timeout issues on high-latency brokers

❌ **No Official Backtesting Framework**
- Repo contains no `.set` backtest profiles, walk-forward methodology, or sample results
- Makes objective performance evaluation difficult
- Users must conduct all validation independently

### Opportunities

🚀 **Multi-Symbol Support**
- Component isolation lends itself well to a multi-instance manager EA
- Could operate 3-5 symbols concurrently with shared risk guard

🚀 **Machine Learning Integration**
- PPM zone classification could be augmented with ONNX model for higher-accuracy entry signals
- MT5 offers native ONNX support; natural upgrade path

🚀 **Backtest Harness**
- Adding dedicated `.set` profile + backtest results section would significantly improve adoption trust
- Walk-forward methodology + out-of-sample validation would strengthen claims

🚀 **MQL5 Port**
- Component architecture translates well to MQL5/MT5
- MT5 offers event-driven `OnBookEvent`, true async execution, hedging mode, and better tick-volume access

🚀 **Risk Research**
- Centralized martingale gate and always-reverse direction are testbeds for further research
- E.g., dynamic step caps based on rolling Sharpe ratio, regime-aware cooldowns

### Threats

⚠️ **Broker Restrictions**
- Many brokers detect and block martingale EAs or impose minimum SL distances that break virtual SL logic
- Prop-firm environments often ban martingale outright

⚠️ **Spread Widening in News Events**
- Even the EMA-adaptive spread filter may not react fast enough to prevent bad fills at step 3–5
- Virtual SL retry logic may fail if slippage exceeds the wide safety SL distance

⚠️ **Market Regime Changes**
- Auto-calibration derives thresholds from recent data
- Regime shift (low-vol → high-vol) invalidates calibrated parameters without warning
- No dynamic re-calibration; users must manually adjust or restart

⚠️ **Regulatory & Over-Reliance on MT4**
- Some jurisdictions/brokers restrict automated martingale strategies, especially in prop-firm environments
- MT4 is aging; future broker support may wane, increasing maintenance burden

⚠️ **Reproducibility**
- Lack of backtests/statistics in the repo makes it hard for users to independently verify edge or risk of ruin
- Users must do all testing themselves; no benchmark to compare against

---

## Design Review

### Architecture & Code Quality

- **Clean Component Boundary**: Facade + 13 SRP classes with explicit wiring; MT4 handlers only delegate; no global mutable state
- **Well-Documented Flows**: Mermaid diagrams for DFD, fresh entry, martingale re-entry, auto-calibration, and equity protection simplify auditing
- **Robustness**: Versioned state files (magic tag `OMM4` = 0x4F4D4D34), day-stamped drawdown baseline, retry on virtual SL close failures, fail-open on indicator errors (e.g., ADX unavailable)
- **Performance Note**: `CRangeScanner::Rescan()` performs O(n) scan on every tick with 1,200-sample window. Min-max deque would be O(1) amortized if performance becomes a concern

### Risk Management Maturity

- EA explicitly labeled high-risk; author emphasizes demo testing first and documents worst-case exposure (e.g., cumulative lots at fixed multiplier)
- **Multiple Overlapping Guards**: Daily drawdown, minimum equity, consecutive-loss pause, ATR-adaptive step caps, ADX gating, cooldowns, ATR spacing, reversal confirmation
- Mature, defense-in-depth approach to containing tail risk in a martingale system

### Observability

- **On-Chart Panel**: Shows range/candle, PPM/zone, spread vs adaptive limit, martingale step and block reasons, loss streak, halt status, and reverse-entry countdown — excellent for real-time monitoring
- **Experts Log**: Detailed event logging; auto-calibration prints ATR and ADX suggestions; step gate reasons reported on block

### Usability & Guidance

- Quick Start, risk profiles (conservative/default/aggressive), loss-flow walkthrough, and FAQ lower barrier to safe experimentation
- Explicit warnings on demo testing and careful parameter selection
- Input descriptions are thorough and include ranges

### Caveats

- Performance metrics/backtests are absent; you must generate your own evidence of edge and drawdown behavior
- Issues are disabled and there's no public CI, reducing external validation signals
- Trust rests on code quality and documentation; no third-party audits visible

---

## Code Quality Verification

The code demonstrates several verified best practices:

- **Bug Fix Documentation**: All 6 bug fixes explicitly documented with `// FIX-N:` comments (e.g., FIX-2 prevents silent downgrade to wide safety SL on failed `OrderClose`; FIX-4 prevents restart from bypassing daily halt)
- **Input Validation**: `OnInit` covers all critical parameter ranges with clear error messages
- **Data Decoupling**: `REENTRY_CONTEXT` struct decouples decision logic from data gathering—clean separation of concerns
- **Versioned State**: Memento pattern uses magic tag (`OMM4` = 0x4F4D4D34) to safely discard incompatible state files
- **Buffer Safety**: `MAX_POSITIONS = 20` cap prevents overruns in `CVirtualStopManager`

---

## Verification & Authenticity

### Provenance
- Repository exists and is public under [`nhasibuan/oneminuteman`](https://github.com/nhasibuan/oneminuteman)
- Clear main branch with commit history and two files: README.md and oneminuteman.mq4
- Recent commits show active development (July 2026), with PR merges, documentation syncs, and feature commits for v10.10–v10.12

### Contributor List
- Human maintainer: nhasibuan (Norman Hasibuan)
- Devin AI integration bot for code assistance
- No suspicious third-party contributors observed

### Consistency Across Artifacts
- README content aligns with commit messages ("Add martingale ATR auto-calibration", "mode-aware ADX trend gate", "centralized consecutive-loss protection", "reverse-entry + force-reverse martingale")
- Internal consistency: Data dictionary matches described structures and enums
- Diagrams coherent and match described flows

### Risk Handling
- README and changelog document concrete mitigations and explicitly enumerate remaining risks
- No false safety claims: Warnings clearly state safeguards mitigate but do not eliminate risk
- Recommends demo testing and cautious parameter choices

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
   - Block reason log (if entry attempts are blocked)
   - Reverse-entry countdown (Reverse:ON done=no in X s)
3. Review Experts log for any warnings or errors
```

#### 3. **Calibrate (Optional Auto-Calibration)**
```
1. Set InpAutoCalibrateMartAtr = true
2. Let the EA run for 60+ bars to sample volatility
3. Read Experts log for "Auto-calibrate:" line
4. Validate suggested ATR thresholds and ADX value for your symbol/broker
5. Adjust InpMartAtrLowPips, InpMartAtrHighPips, InpMartMaxADX manually if needed
6. Set InpAutoCalibrateMartAtr = false and compile
```

#### 4. **Demo Validation (2–4 weeks)**
```
1. Enable trading on demo: InpEnableTrading = true
2. Use conservative risk profile:
   - InpMaxDrawdownPct = 2.0
   - InpMinEquity = 1000
   - InpMartMaxSteps = 3
3. Monitor:
   - Daily drawdown curve
   - Consecutive loss streaks
   - Martingale ladder behavior (step count, lot sizes)
   - Equity guard triggers
   - Time-based reverse-entry firing (~60s after first fill)
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
| `InpUseMartingale` | `true` | Enable martingale loss-recovery re-entries |
| `InpMartMult` | `2.0` | Lot multiplier per re-entry step (fallback when schedule empty) |
| `InpMartMaxSteps` | `5` | Maximum number of martingale re-entries per cycle |
| `InpMartCooldownBars` | `2` | Bars required between re-entries (fallback when schedule empty) |
| `InpMartCooldownSchedule` | `"0,0,1,0,1"` | Progressive per-step cooldown bar counts (overrides `InpMartCooldownBars`) |
| `InpMartMultSchedule` | `"1.0,2.0,1.0,2.0,1.0"` | Per-step lot multiplier schedule (overrides `InpMartMult`) |
| `InpMaxConsecLosses` | `3` | Pause all entries after this many consecutive losses; `0` = disabled |
| `InpConsecLossPauseMin` | `1` | Duration (minutes) of consecutive-loss pause |
| `InpMartMaxADX` | `30.0` | Block reverse re-entry when ADX(M1) is below this value; `0` = disabled |
| `InpMartADXPeriod` | `14` | ADX period for the trend block gate |
| `InpMartMinAtrDist` | `0.5` | Same-bar re-entry needs price move ≥ ATR × this; `0` = require new bar |
| `InpMartConfirm` | `MART_CONFIRM_EITHER` | Reversal confirmation before each re-entry step (NONE/CANDLE/PPM/EITHER/BOTH) |
| `InpMartAtrLowPips` | `0` | ATR-adaptive steps: full steps at or below this ATR pip level; `0` = disabled |
| `InpMartAtrHighPips` | `0` | ATR-adaptive steps: only 2 steps above this ATR pip level; `0` = disabled |
| `InpAutoCalibrateMartAtr` | `false` | Auto-derive ATR low/high pip thresholds from recent M1 bars on init |
| `InpReverseAfterMin` | `true` | Open an opposite-direction position 1 min (configurable) after the first entry |
| `InpReverseDelaySec` | `60` | Seconds to wait before firing the time-based reverse leg |
| `InpReverseLots` | `0.0` | Lot size for the reverse leg; `0` = use `InpBaseLots` |
| `InpAverPeriod` | `14` | SMA period for candle body average and trend classification |
| `InpSampleMs` | `50` | Timer interval (ms) for tick-rate range sampling |
| `InpWindowSize` | `1200` | Ring-buffer size for range scanner (1200 × 50ms = 60s window) |
| `InpUseVolumeFilter` | `true` | Enable tick-volume spike gate for fresh entries |
| `InpVolLookback` | `20` | Bars to average for volume filter baseline |
| `InpVolMultiplier` | `1.5` | Volume must be ≥ average × this multiplier to pass |
| `InpTzOffsetHours` | `7` | Local timezone offset from GMT (e.g., WIB = +7) |
| `InpSessionStartHour` | `5` | Session open hour (local time) |
| `InpSessionEndHour` | `24` | Session close hour (local time) |

---

## Overall Assessment

**OneMinuteMan** is a technically sophisticated, well-documented MT4 scalping EA with extensive, persisted risk controls and active development. The architecture and documentation are strong, and the repository is consistent and continuously maintained.

### Summary

| Aspect | Rating | Notes |
|---|---|---|
| **Architecture** | ⭐⭐⭐⭐⭐ | Clean OOP, 13 SRP components, zero globals |
| **Risk Management** | ⭐⭐⭐⭐⭐ | 7-layer martingale gate, persistent state, ATR-adaptive |
| **Code Quality** | ⭐⭐⭐⭐⭐ | Bug-fix documentation, guard clauses, input validation |
| **Documentation** | ⭐⭐⭐⭐ | Clear README, diagrams, but no official backtest results |
| **Backtesting** | ⭐⭐ | No `.set` profiles or walk-forward results provided |
| **Community/Trust** | ⭐⭐⭐ | Active development, single maintainer, no CI/CD or issue tracker |

### Primary Caveats

1. **Inherent Martingale Risk**: Even with protections, large drawdowns are possible in consecutive-loss sequences
2. **Independent Validation Required**: You must perform your own backtests and demo validation before any live use
3. **No Official Backtest Statistics**: Trust in the EA's edge must rest on your own testing and code/design quality
4. **Broker Restrictions**: Many brokers ban or restrict martingale EAs; verify before live deployment
5. **Hedging Broker Required for Reverse Entry**: `InpReverseAfterMin = true` requires a hedging-capable account; on FIFO/netting accounts the opposite leg will net/close the first position

### Recommendation

✅ **Demo test thoroughly** (2–4 weeks minimum) before live deployment.

✅ **Start with conservative risk profile** (2% daily drawdown, 3–5 martingale steps).

✅ **Monitor on-chart panel and Experts log** to understand entry blocks and martingale progression.

✅ **This is a high-risk, high-effort system** suitable for experienced traders willing to research, validate, and maintain careful risk discipline.

---

## Resources

- **Repository**: [nhasibuan/oneminuteman](https://github.com/nhasibuan/oneminuteman)
- **Author**: [Norman Hasibuan (@nhasibuan)](https://github.com/nhasibuan)
- **Latest Version**: v10.12 (July 14, 2026) — reverse-entry feature + force-reverse martingale; `ENUM_MART_MODE` / `InpMartMode` removed
- **For Issues/Questions**: Refer to repository documentation and risk warnings

---

*OneMinuteMan is a powerful tool for disciplined M1 scalping. Respect the martingale risk, demo thoroughly, and trade responsibly.*
