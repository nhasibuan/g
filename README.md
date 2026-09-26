# HOKKY V5 HEDGE

This project contains a single-file MetaTrader 4 Expert Advisor, `g.mq4`, designed for an ATR-based hedged grid trading system.

## Overview

The EA manages alternating long and short grid positions in a non-netting (hedging) account. It uses ATR-based spacing, trend filters, recovery-lot logic, and basket-level exits to try to manage risk while allowing both directions to operate simultaneously.

## Main features

- Hedged/pendulum grid execution using alternating buy and sell entries
- Trend filter support based on MA/EMA and ADX configuration
- ATR-adaptive distance and protection logic
- Basket-level take-profit and stop-loss behavior
- Trailing stop service per open order
- Recovery lot sizing and capped lot controls
- Persistent global-variable risk state across restarts
- Instance lease protection to avoid duplicate EA execution on the same symbol/account
- Dashboard and journal logging aids

## Important operational conditions

- Requires a hedging (non-netting) account for proper simultaneous long and short positions.
- On netting accounts, long/short positions can cancel each other and break the intended grid logic.
- Slippage is specified in points; volatile assets such as XAUUSD may need much larger values to execute risk exits reliably.
- ATR inputs are multipliers, not pips, and are intended to scale with market volatility.
- The implementation includes drawdown latching and risk resets; the cooldown behavior should be understood before use.

## Risk warning

This is an automated trading system and may lose money in live markets. It is not a guaranteed profit strategy, and it should be evaluated in a demo environment before any real-money deployment. Always test broker compatibility, symbol behavior, and account type before using it operationally.

## Files

- `g.mq4` — Expert Advisor source code
- `README.md` — project notes and operational summary
