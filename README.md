# HOKKY V5 HEDGE

This repository contains a single-file MetaTrader 4 Expert Advisor, `g.mq4`, for an ATR-based hedge-grid strategy on XAU/USD (Gold). It is not a turnkey trading system and should be treated as an experimental trading bot requiring strict validation on demo accounts before any live deployment.

## What the EA does

The EA is designed to manage a hedged grid in a non-netting (hedging) account. In plain terms, it opens alternating long and short trades around a reference price, then adds newer positions as price moves away from the mean. It uses ATR-based spacing, a trend filter, recovery-lot logic, and basket-level exits to try to keep the grid controlled.

From the code, the system attempts to:

- maintain a persistent instance lease so only one chart instance controls the same account/symbol state;
- persist risk state using MetaTrader global variables;
- track ATR and spread conditions before opening or adding trades;
- alternate direction in a pendulum/hedged grid depending on configuration;
- protect against excessive drawdown through equity latches and session drawdown calculations;
- recover lot sizing after basket closure when configured for recovery mode;
- modify or close trades based on basket-level TP/SL logic and trailing stops.

## Operational assumptions

This strategy assumes:

- a hedging account, because simultaneous long and short positions are central to the logic;
- XAU/USD-style execution with relatively wide slippage tolerance and volatile price behavior;
- a broker that supports the requested stop levels and execution quality expected by the inputs;
- valid historical data and a stable trading environment for testing before real-money use.

The code explicitly warns that low slippage values are risky for Gold and recommends values near 30-50 points for XAU/USD. The EA also includes input guards and hard stop settings, but those are operational controls, not guarantees of safe performance.

## Fact-check notes

The code supports the following factual claims:

- The project is a single-file MQL4 Expert Advisor named `g.mq4`.
- The strategy is explicitly built around a hedged grid and ATR-based spacing (`InpDistance`, `InpATRPeriod`, `InpTP`, `InpBasketSL_ATR`, etc.).
- A lease/collision mechanism exists using `GlobalVariableSetOnCondition` and `g_ownerGV`/`g_beatGV` to prevent duplicate EA instances from operating simultaneously.
- Risk-state persistence is implemented with MetaTrader globals such as `NEXTLOT`, `EQSTOP`, `SSTART`, `SBASE`, and `SPEAK`.
- The code includes explicit drawdown and session-tracking logic, including latch resets and cooldowns.

Important caveat: the repository contains strategy code and safeguards, but no evidence here of audited results, live trading approval, or a validated performance record. The presence of risk controls is not proof of profitability or safety.

## Adversarial and failure review

The implementation attempts to be robust, but some attack vectors and failure modes remain important:

- duplicate-chart takeover: if a second instance with the same symbol/account identity becomes active, the lease logic can disarm the primary instance;
- stale or corrupted global state: risk variables can be reset, overwritten, or left inconsistent across chart restarts;
- blow-up from recovery logic: multiplication-based lot escalation can become dangerous under adverse volatility or poor fills;
- spread and slippage risk: gold is volatile, and the system is sensitive to large spikes and partial fills;
- broker execution risk: stop-level, queue priority, and price gap behavior can undermine basket exits and trailing logic;
- netting-account mismatch: the design relies on hedging semantics that do not apply on netting accounts;
- overly optimistic assumptions: ATR and basket-level controls can reduce some risk, but they do not eliminate gap, liquidation, or data-availability risk.

## Risk warning

This EA is a speculative automated trading system. It may lose money in live market conditions and does not guarantee profit. It should be evaluated only in a demo environment with realistic spread/slippage assumptions and risk limits appropriate for the user’s account size and broker conditions.

## Files

- `g.mq4` — Expert Advisor source code
- `README.md` — project notes, operational summary, and risk interpretation
