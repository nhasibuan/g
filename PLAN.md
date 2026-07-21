# OneMinuteMan v10.13-no-mart — Spec & Development Plan

**Source:** [`nhasibuan/g/blob/main/oneminuteman.mq4`](https://github.com/nhasibuan/g/blob/main/oneminuteman.mq4)
**Author:** Norman Hasibuan (@nhasibuan)
**Date:** 2026-07-21
**Status:** Planning

---

## 1. Objective & Scope

Refactor **OneMinuteMan** into a pure, signal-based M1 scalping Expert Advisor for MetaTrader 4. All martingale, grid, averaging, and recovery logics are strictly removed. The result is a single-file, component-based EA that trades only on high-quality confluence signals with stringent risk controls.

### What Changes

| Aspect | v10.12 (current) | v10.13-no-mart (target) |
|---|---|---|
| Martingale controller | Present (`CMartingaleController`, 7-layer gates) | Removed entirely |
| Re-entry logic | Centralized state machine | Removed — only fresh entries |
| Reverse entry (time-based) | Active, independent of martingale | Kept as optional standalone feature |
| Martingale inputs | ~20 parameters | Reduced to 0 (all `InpMart*` removed) |
| State persistence | Includes martingale step, loss streak, pause timers | Simplified: VSL + equity guard only |
| On-chart panel | Shows martingale step, block reasons, cooldown countdowns | Cleaned up — no martingale fields |
| Component count | 13 classes | 12 classes (`CMartingaleController` removed) |
| Version string | `10.12` | `10.13` |
| Estimated file size | ~67 KB | ~61 KB (~489 lines removed) |

### What Stays

- Forced M1 operation via millisecond timer + new-bar detection
- Candle pattern recognition (10 types via `CCandleEngine`)
- ZigZag-based PPM momentum engine (`CPpmEngine`)
- ATR-dynamic SL/TP/trailing/break-even (`CRiskModel`)
- Virtual SL with broker safety-net SL (`CVirtualStopManager`)
- Equity guard + daily drawdown halt (`CEquityGuard`)
- Session clock with timezone awareness (`CSessionClock`)
- Adaptive spread/slippage monitoring (`CSpreadMonitor`)
- Volume spike filter (`CVolumeFilter`)
- Ring-buffer range scanner (`CRangeScanner`)
- State persistence across restarts (`CStateStore`, Memento pattern)
- Single-position-per-symbol constraint (`CTradeExecutor`)

---

## 2. Core Requirements

### 2.1 Execution Environment

- **Forced M1 operation**: Timer fires every `InpSampleMs` (default 50 ms); samples Ask price, updates spread EMA, range scanner, PPM calculation
- **New-bar detection**: On each `OnTick()`, checks if a new M1 bar has formed; processes candle classification and entry evaluation only once per bar
- **Dual-validation**: Both timer and tick paths contribute — timer handles continuous SL enforcement and market data sampling; tick handles bar-level signal processing

### 2.2 Signal Confluence (Fresh Entry Only)

All conditions below must be true **simultaneously** for an entry:

1. Trading enabled (`InpEnableTrading = true`)
2. No open position on the symbol (max 1 position)
3. Inside session hours (timezone-aware)
4. Spread within adaptive limit (EMA-derived)
5. Equity guard passes (min equity + daily drawdown check)
6. PPM zone is MEDIUM or HIGH (ZigZag momentum confirmed)
7. Tick volume ≥ multiplier × average (liquidity spike confirmed)
8. Candle produces a directional signal (pattern + trend aligned)

> **No re-entries, no averaging, no martingale.** If the first entry loses, the EA waits for the next confluence signal independently.

### 2.3 Risk & Trade Management (Strict No-Martingale)

- **ATR-dynamic sizing**: SL, TP, trailing start, trailing step all scale with current ATR
- **Virtual SL**: Hidden from broker; enforced tick-by-tick in memory with retry on failure
- **Safety SL**: Wide real SL sent to broker (default 5× virtual) as disconnect insurance
- **Break-even promotion**: Moves SL to open price + lock pips once profit trigger reached
- **Trailing stop**: Tightens virtual SL progressively once profit exceeds trail start level
- **Daily drawdown halt**: Stops all trading after configured % loss; persists across restarts
- **Equity floor**: Absolute minimum equity threshold; halts trading until next local day
- **Auto-flatten on breach**: Option to force-close positions when equity guard triggers

### 2.4 Optional Time-Based Reverse Entry

Independent of the primary signal engine. When enabled:

- Opens one opposite-direction position at a fixed delay after the first entry
- Does NOT wait for the first position to close
- Uses no confirmation gates (opens immediately after delay elapses)
- Requires hedging-capable broker; on FIFO/netting accounts the opposite leg nets against the first
- Fires only once per cycle (resets when account goes flat)

> ⚠️ **Requires a HEDGING-capable broker.** On FIFO/netting accounts the opposite leg will net/close the first position.

### 2.5 State Persistence

Survives terminal crash, chart re-attach, VPS migration, and recompilation:

- Virtual SL registry (ticket → price mapping)
- Daily drawdown baseline + day stamp
- Halt flag + halt-until timestamp
- Versioned binary format with magic tag (`OMM4` = 0x4F4D4D34) for backward compatibility

---

## 3. Architecture Design (12 OOP Components)

The single `.mq4` file contains exactly **12 classes** (down from 13 by removing `CMartingaleController`). All use `#property strict`. Zero hidden global mutable state.

### 3.1 Component Map

```
CExpertAdvisor (Facade)
├── CSpreadMonitor        — Rolling EMA of bid-ask spread; adaptive max-spread & slippage
├── CRangeScanner         — Ring-buffer of tick High/Low over configurable window (1200×50ms = 60s)
├── CCandleEngine         — Classifies 10 candlestick patterns; derives trend direction vs SMA
├── CPpmEngine            — ZigZag-based Pips-Per-Minute efficiency; zones LOW/MEDIUM/HIGH
├── CVolumeFilter         — Tick-volume spike gate; blocks low-liquidity entries
├── CSessionClock         — Timezone-aware session window; daily halt flag persistence
├── CEquityGuard          — Dual protection: max daily DD% + absolute equity floor
├── CRiskModel            — ATR-dynamic SL/TP/trailing/break-even resolution
├── CVirtualStopManager   — Hidden SL registry with retry logic + wide broker safety SL
├── CTrailingManager      — Break-even promotion + ATR-based trailing stop management
└── CTradeExecutor        — OrderSend dispatcher; emergency flatten; history scanning
 └── CStateStore          — Versioned binary save/load (Memento pattern)
```

### 3.2 Design Patterns in Use

| Pattern | Implementation |
|---|---|
| **Facade** | `CExpertAdvisor` — single entry point delegating all MT4 events |
| **Single Responsibility** | 12 decoupled component classes, each with one clearly-defined purpose |
| **Memento** | `CStateStore` — versioned binary state persistence for crash-safe recovery |
| **Guard Clauses** | No hidden global mutation; all state owned by components; fail-fast early returns |

### 3.3 Component Responsibilities

#### Facade

**`CExpertAdvisor`** — Single entry point routing MT4 events (`OnInit`, `OnDeinit`, `OnTimer`, `OnTick`). Initializes all components, manages the main execution loop, builds the on-chart comment panel.

#### Market Analysis (5 components)

| Class | Responsibility | Key Methods |
|---|---|---|
| `CSpreadMonitor` | Rolling EMA of spread; adaptive limits | `Init(alpha, maxMult, slipMult)`, `Update()`, `SpreadOK()`, `EffSlippage()` |
| `CRangeScanner` | Ring-buffer of tick highs/lows | `Init(windowSize)`, `Sample(price)`, `High()`, `Low()`, `Range()` |
| `CCandleEngine` | OHLC pattern classification | `Init(period)`, `Recognize(shift, &result)`, `SignalDirection(&candle)` |
| `CPpmEngine` | ZigZag pivot scan → PPM calc | `Init(params)`, `VerifyIndicator()`, `Calc(&result)` |
| `CVolumeFilter` | Volume spike detection | `Init(enabled, lookback, mult)`, `Ok()` |

#### Management (4 components)

| Class | Responsibility | Key Methods |
|---|---|---|
| `CSessionClock` | Local time conversion; session windows | `Init(tz, startH, endH)`, `LocalHour()`, `InSession()`, `LocalDayStamp()` |
| `CEquityGuard` | Drawdown % + equity floor | `Init(minEq, maxDD%)`, `Breached(&reason)`, `RollDayIfNeeded(stamp)` |
| `CRiskModel` | ATR-based parameter resolution | `Init(atrP, slMult, tpMult, trailStartMult, trailStepMult, beMult, floor)`, `Resolve(&params)` |
| `CTradeExecutor` | Order dispatch + cleanup | `Init(magic, hideSl, ...)`, `CountPositions()`, `Open(dir, lots, ...)`, `CloseAll(...)` |

#### Post-Trade Operations (3 components)

| Class | Responsibility | Key Methods |
|---|---|---|
| `CVirtualStopManager` | Hidden SL tracking + enforcement | `Register(ticket, dir, vsl, be, safety)`, `Enforce(slippage)`, `Tighten(ticket, ...)` |
| `CTrailingManager` | BE promotion + trailing | `Init(hideSl, beLockPips)`, `Manage(risk, vsl, magic)` |
| `CStateStore` | Binary persistence | `Init(magic)`, `Save(...)`, `Load(...)` — versioned with `STATE_MAGIC` (`OMM4`) |

---

## 4. Input Parameters (Final Specification)

All `InpMart*` parameters are removed. Remaining inputs grouped logically (~45 total, down from ~65):

### Trading Controls

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpEnableTrading` | bool | `false` | Master kill switch — observe-only when false |
| `InpBaseLots` | double | `0.01` | Fixed lot size for all entries |
| `InpMagic` | int | `100` | Unique EA identifier per chart/symbol |

### Risk & Money Management

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpSL_Pips` | double | `0` | Manual SL override in pips; `0` = ATR-dynamic |
| `InpTP_Pips` | double | `0` | Manual TP override in pips; `0` = ATR-dynamic |
| `InpAtrPeriod` | int | `14` | ATR period for dynamic calculations |
| `InpAtrSLMult` | double | `1.5` | Dynamic SL = ATR × this multiplier |
| `InpAtrTPMult` | double | `2.0` | Dynamic TP = ATR × this multiplier |
| `InpAtrTrailStartMult` | double | `1.0` | Trail activation = ATR × this multiplier |
| `InpAtrTrailStepMult` | double | `0.5` | Trail increment = ATR × this multiplier |
| `InpMinRiskPips` | double | `1.0` | Minimum floor for any ATR-derived pip distance |
| `InpHideSL` | bool | `true` | Use virtual (hidden) SL instead of sending to broker |
| `InpUseSafetySL` | bool | `true` | Send wide real SL to broker as disconnect safety net |
| `InpSafetySLMult` | double | `5.0` | Safety SL distance = virtual SL × this multiplier |
| `InpBE_TriggerMult` | double | `1.0` | Break-even activates at ATR × this multiplier |
| `InpBE_LockPips` | double | `1.0` | Pips to lock above breakeven |
| `InpSlippage` | int | `0` | Max slippage in points; `0` = auto from spread EMA |
| `InpMaxSpread` | int | `0` | Max spread in points; `0` = auto from spread EMA |
| `InpMaxDrawdownPct` | double | `10.0` | Halt trading if daily drawdown ≥ this % |
| `InpMinEquity` | double | `100.0` | Halt trading if equity falls below this value |
| `InpCloseOnGuardBreach` | bool | `true` | Force-close positions when equity guard triggers |

### Signal Engine

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpAverPeriod` | int | `14` | SMA period for candle body average and trend classification |
| `InpSampleMs` | int | `50` | Millisecond timer interval for tick-range sampling |
| `InpWindowSize` | int | `1200` | Ring-buffer size (1200 × 50ms = 60-second window) |
| `InpZzDepth` | int | `2` | ZigZag Depth parameter |
| `InpZzDeviation` | int | `2` | ZigZag Deviation parameter |
| `InpZzBackstep` | int | `1` | ZigZag Backstep parameter |
| `InpZzLookback` | int | `100` | Bars scanned for ZigZag pivots |
| `InpPpmMinHigh` | double | `2.0` | PPM threshold for HIGH zone |
| `InpPpmTarget` | double | `4.0` | PPM target — ideal entry zone boundary |
| `InpAtrDailyRef` | double | `1.5` | Volatility reference for PPM display ratio |
| `InpShowPPM` | bool | `true` | Show PPM value in on-chart panel |

### Volume Filter

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseVolumeFilter` | bool | `true` | Enable tick-volume spike gate |
| `InpVolLookback` | int | `20` | Bars averaged for volume baseline |
| `InpVolMultiplier` | double | `1.5` | Volume must be ≥ average × this to pass |

### Spread Adaptation

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpSprEmaAlpha` | double | `0.05` | EMA smoothing factor for spread (0, 1] |
| `InpMaxSpreadMult` | double | `2.5` | Max spread = EMA × this multiplier |
| `InpSlippageMult` | double | `1.5` | Slippage = EMA × this multiplier |

### Session & Timezone

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpTzOffsetHours` | int | `7` | Local timezone offset from GMT (**WIB = +7**) |
| `InpSessionStartHour` | int | `5` | Session open hour (local time) |
| `InpSessionEndHour` | int | `24` | Session close hour (local time) |

### Time-Based Reverse Entry (Optional)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpReverseAfterMin` | bool | `true` | Open opposite position after delay |
| `InpReverseDelaySec` | int | `60` | Seconds to wait before firing reverse leg |
| `InpReverseLots` | double | `0.0` | Reverse leg lots; `0` = use base lots |

---

## 5. Implementation Steps

### Phase 1: Martingale Eradication

**Goal:** Remove all martingale-related code, inputs, enums, and state.

1. Delete `CMartingaleController` class entirely (currently Section 13 of source)
2. Delete `REENTRY_CONTEXT` struct (used exclusively by martingale)
3. Delete `ENUM_MART_CONFIRM` enum (only used by martingale)
4. Remove all `InpMart*` input parameters (~20 lines):
   - `InpUseMartingale`, `InpMartMult`, `InpMartMaxSteps`, `InpMartCooldownBars`
   - `InpMartCooldownSchedule`, `InpMartMultSchedule`, `InpMaxConsecLosses`
   - `InpConsecLossPauseMin`, `InpMartMaxADX`, `InpMartADXPeriod`
   - `InpMartMinAtrDist`, `InpMartConfirm`, `InpMartAtrLowPips`
   - `InpMartAtrHighPips`, `InpAutoCalibrateMartAtr`
5. Remove all references to `m_mart` member variable from `CExpertAdvisor`
6. Remove `BuildReentryContext()`, `NewBarSinceLoss()` methods from facade
7. Remove `m_mart.` calls from `ManageEntries()`, `OnDeinitHandler()`, `OnInitHandler()`
8. Simplify `UpdateTradeState()` — remove `m_mart.OnPositionClosed()` call
9. Clean `UpdateComment()` — remove martingale step, block reason, cooldown countdown, consecutive losses, pause status lines
10. Remove `ResetCycle()`, `CanReenter()`, `ReentryAllowed()`, `ConfirmationOK()` and all martingale state from facade

### Phase 2: Simplified Entry Logic

**Goal:** Rewrite `ManageEntries()` for fresh-signals-only flow.

New `ManageEntries()` pseudocode:

```
ManageEntries(bool allowFresh):
    if !InpEnableTrading              → return
    if m_exec.CountPositions() > 0    → return
    if !TradingWindowOpen()           → return
    if !m_spread.SpreadOK()           → return
    if !EquityGuardOK()               → return
    if !allowFresh                    → return
    if !m_candle_valid                → return
    if !m_ppm_valid                   → return
    if m_ppm.zone < PPM_ZONE_MEDIUM   → return
    if !m_volume.Ok()                 → return

    dir = m_candle_engine.SignalDirection(m_candle)
    if dir == 0                       → return

    lots = NormalizeLots(InpBaseLots)
    if m_exec.Open(dir, lots, m_risk, m_vsl, m_spread.EffSlippage()):
        SaveState()
```

Key simplifications:
- No martingale path branching
- No re-entry context building
- No cooldown/block-reason tracking
- Single decision point per M1 bar
- Lot size is always `InpBaseLots` (no multiplier schedules)

### Phase 3: Reverse Entry Isolation

**Goal:** Keep time-based reverse as an independent optional module.

- `ManageReverseEntry()` remains unchanged — already operates independently
- Remove dependency on `m_first_dir` / `m_first_open_time` being cleared by martingale reset
- Clarify in comments: reverse entry does not participate in the primary signal chain
- Retain broker hedging caveat in inline comment

### Phase 4: State Store Simplification

**Goal:** Reduce persisted state to essentials only.

Remove from `CStateStore.Save()`:
- Martingale step counter
- Last trade direction
- Last trade lots
- Await-reentry flag
- Last loss time
- Consecutive loss count
- Pause-until timestamp
- Last loss price

Keep in `CStateStore.Save()`:
- Halted flag + halt-until timestamp
- Day baseline balance
- Day stamp
- Virtual SL registry entries

### Phase 5: Initialization Cleanup

**Goal:** Streamline `OnInitHandler()`.

1. Remove `m_mart.Init(...)` call
2. Remove `InpAutoCalibrateMartAtr` block (entire percentile derivation section ~80 lines)
3. Remove `m_mart.SetAtrThresholds()` call
4. Remove `m_mart` validation inputs (`InpMartMult <= 0`, `InpMartCooldownBars < 0`, etc.)
5. Simplify state load — remove martingale restore logic
6. Update version string from `"10.12"` to `"10.13"`
7. Update `#property description` text

### Phase 6: Code Quality & Documentation

**Goal:** Final polish.

1. Review all comments — remove references to martingale, re-entry, recovery
2. Ensure `// FIX-N:` comments remain intact (they document previous bugs)
3. Verify zero compiler warnings under `#property strict`
4. Confirm single-trading-decision-per-bar invariant
5. Check that no dead code paths remain
6. Update header copyright/version block
7. Run mental compilation trace: `OnInit → OnTimer → OnTick → OnDeinit`

---

## 6. Verification Criteria

### Pre-Deployment Testing

| Criterion | Expected Result |
|---|---|
| **Compilation** | `0 errors`, `0 warnings` under `#property strict` |
| **No martingale traces** | Zero references to `CMartingaleController`, `m_mart`, `REENTRY_CONTEXT`, `ENUM_MART_CONFIRM`, `MART_CONFIRM_*` |
| **Single entry per bar** | `ManageEntries()` called once per new bar; no loops, no recursion |
| **Max 1 position** | `CTradeExecutor.CountPositions()` never allows > 1 open position per symbol/magic |
| **Guards active** | Equity guard, spread monitor, session clock all fire correctly |
| **State persistence** | Virtual SL survives terminal restart; halt flag survives restart; no martingale state corruption |
| **Reverse entry** | Fires once per cycle at correct delay; requires hedging broker |
| **Deterministic output** | Same market data + same inputs → identical trade sequence (no uninitialized variables) |
| **Panel cleanliness** | On-chart comment shows signal info, PPM, spread, session, reverse countdown — no martingale fields |

### Code Review Checklist

| Gate | Requirement |
|---|---|
| **SRP compliance** | Each class has exactly one responsibility; no cross-cutting logic |
| **Guard clauses** | Early returns for invalid conditions; no deep nesting |
| **Zero globals** | All state owned by component instances; `g_ea` is the sole global |
| **Fail-fast** | Invalid inputs rejected in `OnInitHandler()` with clear error messages |
| **Indicator caching** | `iATR()`, `iCustom(ZigZag)` called once per bar maximum |
| **Versioned state** | Magic tag `OMM4` present; old format files safely discarded |
| **Buffer safety** | `MAX_POSITIONS = 20` cap respected in `CVirtualStopManager` |
| **Naming consistency** | `Inp*` prefix for inputs, `m_` prefix for members, PascalCase for classes |
| **Logging completeness** | `Print()` statements for init, errors, halts, reverses, VSL actions |
| **Documentation alignment** | This PLAN.md matches the actual code structure and behavior |

---

## 7. Risk Model (Post-Martingale)

Without martingale recovery, the risk profile shifts fundamentally:

| Aspect | With Martingale (v10.12) | Without Martingale (v10.13) |
|---|---|---|
| Loss recovery | Automatic re-entry cascade | None — accept the loss, wait for next signal |
| Max concurrent exposure | Exponential (lots × multiplier^n) | Linear (always `InpBaseLots`) |
| Worst-case drawdown | Unbounded (limited only by equity guard) | Bounded by daily DD% halt + min equity floor |
| Psychological pressure | High (chasing losses) | Low (fixed risk per trade) |
| Win rate requirement | Lower (recovery compensates) | Higher (each trade stands alone) |
| Suitability | Aggressive, experienced traders | Conservative, disciplined traders |

### Recommended Conservative Profile

| Parameter | Value | Rationale |
|---|---|---|
| `InpBaseLots` | `0.01` | Minimum viable lot |
| `InpMaxDrawdownPct` | `2.0` | Very tight daily halt |
| `InpMinEquity` | `1000.0` | Higher floor than default 100 |
| `InpCloseOnGuardBreach` | `true` | Always flatten on breach |
| `InpReverseAfterMin` | `false` | Disable reverse initially |
| `InpUseVolumeFilter` | `true` | Require liquidity confirmation |
| `InpVolMultiplier` | `1.5` | Moderate spike threshold |
| `InpPpmMinHigh` | `2.0` | Standard medium zone |
| `InpPpmTarget` | `4.0` | Standard high zone |

---

## 8. File Structure (Logical Sections)

The final single-file `.mq4` will contain these sections in order:

```
SECTION 0  — Copyright, property directives, architecture comment block
SECTION 1  — Input parameters (cleaned, ~45 params total)
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
SECTION 13 — CTradeExecutor       ← formerly Section 14
SECTION 14 — CStateStore           ← formerly Section 15
SECTION 15 — CExpertAdvisor        ← formerly Section 16 (facade, simplified)
SECTION 16 — MT4 event handlers    ← delegates to g_ea facade instance
```

Total sections: **17** (down from 18 by eliminating the martingale section).

---

## 9. Change Summary — Line-Level Impact Estimate

| Area | Lines Added | Lines Removed | Net Change |
|---|---|---|---|
| Inputs (`InpMart*` removal) | 0 | ~20 | -20 |
| Enums (`ENUM_MART_CONFIRM`) | 0 | ~7 | -7 |
| Structs (`REENTRY_CONTEXT`) | 0 | ~7 | -7 |
| `CMartingaleController` class | 0 | ~200 | -200 |
| `CExpertAdvisor` facade | ~30 | ~150 | -120 |
| `CStateStore` persist hooks | ~10 | ~30 | -20 |
| `OnInitHandler` validation/init | ~5 | ~80 | -75 |
| `OnTimerHandler` / `OnTickHandler` | 0 | ~10 | -10 |
| `UpdateComment` panel | ~5 | ~15 | -10 |
| Header/version strings | ~2 | ~2 | 0 |
| Comments/docstrings | ~20 | ~30 | -10 |
| **TOTAL** | **~72** | **~561** | **-489** |

Expected final file size: ~61 KB (down from ~67 KB).

---

## 10. Known Limitations & Caveats

1. **No recovery mechanism** — Losing trades stand alone. The EA cannot "average down" or "recover" with cascading entries. This is intentional and reduces complexity/drawdown risk.

2. **ZigZag repaint** — The built-in ZigZag indicator redraws past pivots. PPM values for incomplete bars may change. Mitigated by using `m_ppm_valid` flag and only entering on confirmed (closed) bars.

3. **Single-file constraint** — At ~61 KB, the file approaches MQL4 practical limits. Adding more features would require splitting into multiple files (not possible in standard MT4 EAs without DLLs).

4. **Broker dependency** — Virtual SL requires reliable `OrderClose` execution. Network latency or broker-side restrictions can cause missed virtual stops. Safety SL provides partial mitigation.

5. **Time-based reverse requires hedging** — On FIFO/netting-broker accounts, opening an opposite position while the first is still open will net/close rather than run as two legs.

6. **No backtesting evidence** — This EA has no official `.set` profiles, walk-forward results, or statistical edge verification. Users must validate independently on demo.

---

## 11. Development Workflow

```
Step 1:  Create backup of current oneminuteman.mq4
Step 2:  Remove ENUM_MART_CONFIRM, REENTRY_CONTEXT, InpMart* inputs
Step 3:  Delete CMartingaleController class (Section 13)
Step 4:  Simplify CStateStore ReadFrom/WriteTo (remove martingale fields)
Step 5:  Rewrite ManageEntries() for fresh-signals-only
Step 6:  Strip m_mart references from CExpertAdvisor facade
Step 7:  Clean UpdateComment() panel
Step 8:  Remove auto-calibration block from OnInitHandler
Step 9:  Update version string to 10.13
Step 10: Compile in MetaEditor — fix any warnings/errors
Step 11: Test on demo M1 chart — verify signals, guards, reverse entry
Step 12: Verify state persistence (restart MT4 with open trade)
Step 13: Commit with descriptive message
```

---

## 12. Success Definition

The project is complete when all of the following are confirmed:

- [ ] Compiles cleanly with `#property strict`, zero errors, zero warnings
- [ ] All `InpMart*` parameters removed — search confirms zero occurrences
- [ ] `CMartingaleController` class deleted — no references anywhere
- [ ] `REENTRY_CONTEXT` struct deleted
- [ ] `ENUM_MART_CONFIRM` enum deleted
- [ ] `ManageEntries()` executes only fresh signal logic
- [ ] `CStateStore` saves/loads only VSL + equity guard + halt state
- [ ] On-chart panel shows clean signal info without martingale fields
- [ ] Time-based reverse entry works independently
- [ ] State persistence verified across terminal restart
- [ ] Daily drawdown halt and equity floor functional
- [ ] Virtual SL enforcement working (tested in strategy tester)
- [ ] Version string updated to `10.13`
- [ ] All comments consistent with non-martingale design
- [ ] This PLAN.md and README.md updated to reflect v10.13 changes

---

## 13. Design Principles (Non-Negotiable)

- **Single Responsibility Principle (SRP)** — Each class handles exactly one domain
- **Guard Clauses** — Methods fail-fast with early `return` for invalid data
- **No hidden global state** — All mutable state owned by named component instances
- **Deterministic execution** — Same inputs + same market data = identical trade sequence
- **Fail-fast error handling** — Invalid parameters rejected at `OnInit` with clear log messages
- **One trade decision per M1 bar** — No loops, no recursion, no tick-level entry stacking

## 14. Trading Constraints (Non-Negotiable)

- Maximum **one open position** per symbol/magic number at all times
- **No** averaging, martingale, grid, hedging, or pyramiding
- Entries only on confirmed, closed-bar signals
- No repaint-dependent decisions (bar-close validation for ZigZag pivots)
- `OrdersTotal()` for the specific magic + symbol must never exceed 1; emergency close protocol triggered on violation

---

*OneMinuteMan v10.13-no-mart is a disciplined, signal-only M1 scalper. Fixed risk per trade. No recovery. Demo test thoroughly before any live deployment.*
