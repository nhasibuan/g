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

### Martingale Design (v10.10–v10.11)

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
- Re-entries are always **reverse-direction** — each re-entry opens in the opposite direction of the prior (closed) position to exploit mean reversion. The former `SAME_DIRECTION` option has been removed.

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
- Centralized martingale gate and mode-aware ADX logic are testbeds for further research
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
- **Robustness**: Versioned state files (magic tag `OMM4`), day-stamped drawdown baseline, retry on virtual SL close failures, fail-open on indicator errors (e.g., ADX unavailable)
- **Performance Note**: `CRangeScanner::Rescan()` performs O(n) scan on every tick with 1,200-sample window. Min-max deque would be O(1) amortized if performance becomes a concern

### Risk Management Maturity

- EA explicitly labeled high-risk; author emphasizes demo testing first and documents worst-case exposure (e.g., cumulative lots at fixed multiplier)
- **Multiple Overlapping Guards**: Daily drawdown, minimum equity, consecutive-loss pause, ATR-adaptive step caps, ADX gating, cooldowns, ATR spacing, reversal confirmation
- Mature, defense-in-depth approach to containing tail risk in a martingale system

### Observability

- **On-Chart Panel**: Shows range/candle, PPM/zone, spread vs adaptive limit, martingale step and block reasons, loss streak, and halt status—excellent for real-time monitoring
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
- Recent commits show active development (July 2026), with PR merges, documentation syncs, and feature commits for v10.10–v10.11

### Contributor List
- Human maintainer: nhasibuan (Norman Hasibuan)
- Devin AI integration bot for code assistance
- No suspicious third-party contributors observed

### Consistency Across Artifacts
- README content aligns with commit messages ("Add martingale ATR auto-calibration", "mode-aware ADX trend gate (v10.11)", "centralized consecutive-loss protection")
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
3. Review Experts log for any warnings or errors
```

#### 3. **Calibrate (Optional Auto-Calibration)**
```
1. Set InpAutoCalibrateMartAtr = true
2. Let the EA run for 60+ bars to sample volatility
3. Read Experts log for "Auto-calibrate:" line
4. Validate suggested ATR thresholds and ADX value for your symbol/broker
5. Adjust InpMartAtrThreshLow, InpMartAtrThreshHigh, InpMartAdxThresh manually if needed
6. Set InpAutoCalibrateMartAtr = false and compile
```

#### 4. **Demo Validation (2–4 weeks)**
```
1. Enable trading on demo: InpEnableTrading = true
2. Use conservative risk profile:
   - InpMaxDailyDrawdownPct = 2.0
   - InpMinEquity = 1000
   - InpMaxDailyLoss = 100
3. Monitor:
   - Daily drawdown curve
   - Consecutive loss streaks
   - Martingale ladder behavior (step count, lot sizes)
   - Equity guard triggers
4. Only after 2–4 weeks of stable demo results consider live with 1/10th position size
```

---

## Input Parameters (Key Subset)

| Input | Default | Purpose |
|---|---|---|
| `InpEnableTrading` | false | Master kill switch |
| `InpMaxDailyDrawdownPct` | 2.0 | Daily loss halt (%) |
| `InpMinEquity` | 1000 | Absolute equity floor |
| `InpMaxConsecLosses` | 3 | Consecutive-loss pause trigger |
| `InpMartMaxSteps` | 5 | Max re-entry steps per cycle |
| `InpMartInitLotMult` | 1.0 | Initial lot multiplier |
| `InpMartDecaySchedule` | "1.0,1.0,1.0,1.0,1.0" | Lot decay per step |
| `InpAutoCalibrateMartAtr` | false | Enable on-init calibration |
| `InpMartAtrThreshLow` | 5.0 | Low-volatility PPM entry gate |
| `InpMartAtrThreshHigh` | 15.0 | High-volatility PPM entry gate |
| `InpMartAdxThresh` | 30.0 | ADX trend strength gate |
| `InpMartMinAtrDist` | 1.5 | Same-bar ATR price-spacing floor |
| `InpAutoFlattenOnGuardBreach` | false | Auto-flatten if equity guard triggers |
| `InpReverseAfterMin` | true | Open opposite position 1 min after first entry |
| `InpReverseDelaySec` | 60 | Delay before reverse entry (seconds) |
| `InpReverseLots` | 0.0 | Reverse-leg lot size (0 = use `InpBaseLots`) |

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

### Recommendation

✅ **Demo test thoroughly** (2–4 weeks minimum) before live deployment.

✅ **Start with conservative risk profile** (2% daily drawdown, 3–5 martingale steps).

✅ **Monitor on-chart panel and Experts log** to understand entry blocks and martingale progression.

✅ **This is a high-risk, high-effort system** suitable for experienced traders willing to research, validate, and maintain careful risk discipline.

---

## Resources

- **Repository**: [nhasibuan/oneminuteman](https://github.com/nhasibuan/oneminuteman)
- **Author**: [Norman Hasibuan (@nhasibuan)](https://github.com/nhasibuan)
- **Latest Commit**: July 10, 2026 (v10.11 mode-aware ADX gate fix)
- **For Issues/Questions**: Refer to repository documentation and risk warnings

---

*OneMinuteMan is a powerful tool for disciplined M1 scalping. Respect the martingale risk, demo thoroughly, and trade responsibly.*
