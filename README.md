# OneMinuteMan – MT4 M1 Scalping Expert Advisor

## What This Is

**OneMinuteMan** is a MetaTrader 4 Expert Advisor (EA) written in MQL4, designed for M1 (1‑minute) scalping with a martingale recovery layer and comprehensive risk mitigations. It's a single `.mq4` file, internally organized into 13 single‑responsibility classes behind a `CExpertAdvisor` facade, and it's heavily documented with PRD, architecture, DFD, UML sequences, data dictionary, user guide, inputs, changelog, and risk warnings.

---

## Core Idea

- **Every 50 ms timer tick**: Samples Ask, updates spread EMA, range, PPM (Pips‑Per‑Minute), and enforces hidden (virtual) stop‑losses.
- **Each new M1 bar (OnTick)**: Recognizes the closed candle's pattern/trend, checks PPM zone and tick‑volume spike, evaluates entry/martingale rules, and persists protection state so restarts don't bypass safety mechanisms.

---

## Key Components

### Signal & Market Analysis
- **CSpreadMonitor**: Rolling spread EMA → adaptive max‑spread & slippage (symbol‑agnostic).
- **CRangeScanner**: Circular tick buffer → rolling 60s high/low (informational).
- **CCandleEngine**: Classifies 10 candlestick patterns on the last closed M1 bar + trend vs SMA; emits directional signals (Hammer/Doji as reversals, Marubozu in trend as continuation).
- **CPpmEngine**: ZigZag(2‑2‑1) pivots → PPM = pips per minute on the last leg; classifies efficiency zone (LOW/MEDIUM/HIGH).
- **CVolumeFilter**: Gates entries when tick volume ≥ multiplier × average.

### Session & Risk Management
- **CSessionClock**: Timezone‑aware session window; daily halt persists across restarts.
- **CEquityGuard**: Two guards (max daily drawdown % and min equity floor) evaluated on every tick, even with open positions; can flatten on breach (`InpCloseOnGuardBreach`). Baseline is day‑stamped and persisted.
- **CRiskModel**: ATR‑dynamic SL/TP/trailing/break‑even with manual overrides and a minimum risk floor.

### Protection & Execution
- **CVirtualStopManager**: Hidden SL registry with retries; plus a wide broker "safety SL" for disconnect protection.
- **CTrailingManager**: ATR trailing + break‑even lock.
- **CMartingaleController**: Centralized re‑entry decision point (`ReentryAllowed`) with multiple gates and state machine (step, direction, lot schedule, cooldown, loss streak, halt).
- **CTradeExecutor**: `OrderSend` with dynamic params; emergency flatten; history scan; ensures at most one open position per symbol.
- **CStateStore**: Versioned binary save/load (Memento) of full protection state (martingale cycle, halt flags, drawdown baseline, VSL entries); old formats discarded safely.

---

## Signal Logic (Fresh Trades)

**All conditions must be true:**

1. Trading enabled (`InpEnableTrading = true`)
2. No open position on the symbol
3. Inside session hours
4. Spread within adaptive limit
5. Equity guard passes (min equity + drawdown check)
6. PPM zone is MEDIUM or HIGH
7. Tick volume ≥ multiplier × average
8. Candle produces a directional signal (pattern + trend)

---

## Martingale Design

- **Modes**: SAME_DIRECTION (average down) or REVERSE_DIRECTION (alternate direction after each loss). Stops after `InpMartMaxSteps` re‑entries; then halts until next session; halt persists.
- **Centralized Gates** (since v10.10) in `ReentryAllowed`:
  - Idle state check
  - Consecutive‑loss pause
  - ATR‑adaptive step cap
  - Progressive cooldown
  - New‑bar/ATR spacing floor
  - Mode‑aware ADX trend gate
  - Reversal confirmation (candle and/or PPM)
- **Decaying Multiplier Schedule**: (e.g., 2.0, 1.8, 1.6, 1.4, 1.2) to reduce worst‑case drawdown; supports auto‑calibration of ATR thresholds and prints ADX suggestions.

---

## Execution & State

- **Adaptive Execution**: Max spread and slippage from rolling spread EMA (multipliers), making it symbol‑agnostic.
- **State Persistence**: Saves on every trade/halt/deinit; restores on init; handles restart, reattach, VPS migration, and recompilation safely.

---

## SWOT Analysis

### Strengths

✅ **Architecture & Documentation**
- Single‑file yet cleanly componentized (13 SRP classes), with explicit wiring, Mermaid sequence diagrams, data dictionary, PRD, and changelog. Well above typical MQL4 EA quality.

✅ **Comprehensive Protection Model**
- Virtual (hidden) SL with retry on close failures; wide safety SL for disconnects
- Equity guards (daily drawdown % and min equity floor) evaluated every tick and persisted; can auto‑flatten on breach
- Martingale safeguards: ATR‑adaptive step caps, progressive cooldowns, ATR price‑spacing floor, mode‑aware ADX gate, reversal confirmation, consecutive‑loss pause, decaying multiplier schedules

✅ **Adaptive, Symbol‑Agnostic Design**
- Spread/slippage adapt via rolling EMA; ATR‑derived risk distances; PPM & volume filters; no hardcoded pair profiles

✅ **Operational Resilience**
- State persistence (versioned binary) survives restarts, chart re‑attach, VPS migration, recompilation; discards old formats safely
- Fail‑open behaviors for runtime indicator errors (e.g., ADX unavailable → gate skipped)

✅ **Transparency & Guidance**
- Explicit risk warnings in README; on‑chart panel with clear status and block reasons; risk profiles (conservative/default/aggressive) and worst‑case exposure guidance; FAQ for common operational questions

---

### Weaknesses

❌ **Inherent Martingale Risk**
- Even with safeguards, martingale can produce large, fast drawdowns. README explicitly warns that mitigations do not eliminate blow‑up risk.

❌ **Hidden (Virtual) SL Dependency**
- Virtual SL enforcement requires the terminal to stay connected and the timer to fire. Safety SL is wide by design and does not fully replace tight risk control.

❌ **M1 Scalping Frictions**
- M1 strategies are sensitive to spread, slippage, and commission. PPM/volume filters may block many entries, reducing opportunity set.

❌ **MT4 Platform Constraints**
- No CI/CD or automated tests visible; no releases or tags; Issues/PRs are unused. These reduce external quality assurance signals.

❌ **Concentrated Contributor Base**
- Essentially a single maintainer plus a Devin AI integration bot. Bus factor is low.

---

### Opportunities

🚀 **Portability & Tooling**
- Design could be ported to MQL5/MT5 or other C‑like trading platforms. Component boundaries make unit testing plausible if extracted.

🚀 **Parameterization for More Markets**
- Symbol‑agnostic spread/risk logic and PPM engine are already generic. Minor tuning could expand target instruments.

🚀 **Community & Trust**
- Adding example backtest reports, CI checks (even basic syntax), and an open issue tracker would improve adoption confidence and external contributions.

🚀 **Risk Research**
- Centralized martingale gate and ADX mode‑aware logic are good testbeds for further research (e.g., dynamic step caps, regime filters).

---

### Threats

⚠️ **Regulatory & Broker Risk**
- Many brokers restrict or discourage scalping/martingale. Usage could conflict with terms of service or risk policy.

⚠️ **Market Regime Changes**
- High‑impact news, low liquidity, or spread spikes can bypass filters or cause safety‑SL to be hit. PPM/volume relationships can shift.

⚠️ **Over‑Reliance on MT4**
- MT4 is aging; future broker support may wane, increasing maintenance burden.

⚠️ **Reproducibility**
- Lack of backtests/statistics in the repo makes it hard for users to independently verify edge or risk of ruin. Users must do their own testing.

---

## Design Review

### Design & Architecture
- **Clean**: Facade + 13 SRP components with explicit responsibilities; MT4 handlers only delegate; no global mutable state.
- **Well‑Documented Flows**: Mermaid diagrams for DFD, fresh entry, martingale re‑entry, auto‑calibration, and equity protection make behavior easier to audit and reason about.
- **Robustness**: Versioned state files, day‑stamped drawdown baseline, retry on virtual SL close failures, and fail‑open on indicator errors improve reliability.

### Risk Management
- EA is explicitly labeled high‑risk and uses martingale; author consistently emphasizes demo testing first and documents worst‑case exposure.
- **Multiple Overlapping Guards**: Daily drawdown, minimum equity, consecutive‑loss pause, ATR‑adaptive step caps, ADX gating, cooldowns, ATR spacing, and reversal confirmation. Mature approach to containing tail risk in a martingale system.

### Observability
- **On‑Chart Panel**: Shows range/candle, PPM/zone, spread vs adaptive limit, martingale step and block reasons, loss streak, and halt status—excellent for real‑time monitoring.

### Usability & Guidance
- Quick Start, risk profiles, loss‑flow walkthrough, and FAQ lower the barrier to safe experimentation and help avoid common misconfigurations.

### Caveats
- Performance metrics/backtests are absent; you must generate your own evidence of edge and drawdown behavior.
- Issues are disabled and there's no public CI, so external validation is limited; trust rests on code quality and documentation.

---

## Verification

### Authenticity & Provenance
- Repository exists and is public under `nhasibuan/oneminuteman`, with a clear main branch, commit history, and two files: README.md and oneminuteman.mq4.
- Recent commits show active development (July 2026), with PR merges, documentation syncs, and feature commits for v10.10–v10.11, including centralized martingale protections and mode‑aware ADX gate.
- Contributor list shows human maintainer nhasibuan (Norman) and a Devin AI integration bot; no suspicious third‑party contributors observed.

### Consistency Across Artifacts
- README content aligns with commit messages (e.g., "Add martingale ATR auto‑calibration"; "mode‑aware ADX trend gate (v10.11)"; "centralized consecutive‑loss protection").
- Internal consistency: Data dictionary matches described structures and enums.
- Diagrams are coherent and match described flows (DFD, fresh entry, martingale re‑entry, auto‑calibration, equity protection).

### Risk‑Handling Claims
- README and changelog document concrete mitigations and explicitly enumerate remaining risks.
- No false safety claims: Warnings clearly state that safeguards mitigate but do not eliminate risk; recommend demo testing and cautious parameter choices.

---

## Getting Started

### Operational Checks

#### 1. **Compile**
Copy `oneminuteman.mq4` to `MQL4/Experts` and compile in MetaEditor. Ensure ZigZag indicator is present (OnInit verifies it).

#### 2. **Observe First**
Attach to M1 chart with `InpEnableTrading=false`. Review on‑chart panel and Experts log. Check spread, PPM zone, candle classification, and block reasons before enabling trading.

#### 3. **Calibrate**
Optionally use `InpAutoCalibrateMartAtr=true` with 60+ bars. Read the Experts log "Auto-calibrate:" line and validate ATR thresholds and ADX suggestions for your symbol/broker.

#### 4. **Demo Validation**
Run for 2–4 weeks in demo. Monitor daily drawdown, consecutive losses, and martingale ladder behavior. Only then consider live with conservative risk profile.

---

## Overall Assessment

**OneMinuteMan** is a technically sophisticated, well‑documented MT4 scalping EA with extensive, persisted risk controls. The architecture and documentation are strong, and the repository is consistent and active.

### Primary Caveats
- **Inherent martingale risk**: Even with protections, large drawdowns are possible.
- **Independent validation required**: You must perform your own backtests and demo validation before any live use.
- **No official backtest statistics**: Trust in the EA's edge must rest on your own testing and the quality of the code/design.

### Recommendation
Demo test thoroughly before live deployment. This is a high‑risk, high‑effort scalping system suitable for experienced traders willing to research and validate before risking capital.

---

*For issues, feature requests, or questions, please refer to the repository documentation and risk warnings.*
