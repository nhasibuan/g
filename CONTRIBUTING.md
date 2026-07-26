# Contributing to OneMinuteMan

Thank you for your interest in contributing. This is a single-maintainer project for a **real-money trading EA** — changes have financial risk consequences, so the bar for contributions is deliberately high.

## Before You Open a PR

1. **Discuss first.** Open a GitHub Issue describing what you want to change and why, before writing code.
2. **Demo-test your change.** Any logic change to entry gates, risk management, or state persistence must be tested in the MT4 Strategy Tester and ideally on a demo account.
3. **No new external dependencies.** The EA must remain a single `.mq4` file with zero `#include` statements and zero DLL calls.

## PR Requirements

All pull requests must:

- [ ] **Compile cleanly** in MetaEditor with `#property strict` — zero errors, zero warnings
- [ ] **Not break the state format** without bumping `STATE_MAGIC` and updating `CStateStore::Save` / `CStateStore::Load`
- [ ] **Maintain the 13-class SRP architecture** — no adding logic to the `CExpertAdvisor` facade that belongs in a component
- [ ] **Have a human reviewer** — PRs reviewed only by AI bots will not be merged
- [ ] **Include a PLAN.md entry** describing what changed, why, and how it was tested
- [ ] **Update the input count** in README.md if inputs were added or removed

## MT4 Compile Check (Manual)

Since there is no CI pipeline yet, verify compilation manually:

```
1. Open MetaEditor (F4 in MT4)
2. File → Open → oneminuteman.mq4
3. Press F7 (Compile)
4. Check "Errors" tab — must show 0 errors, 0 warnings
```

## Code Style

- Guard clauses over nested `if` blocks
- No global mutable state — all state lives in class members
- Every `OrderSend` return must be checked and logged with `Print()`
- Comment all magic numbers with a `//` explaining the value

## What We Will NOT Accept

- Martingale / position sizing multipliers (removed in v10.13)
- Any `#import` or DLL dependency
- Changes that bypass the equity guard or daily drawdown halt
- Force-push to `main`

## Contact

Open a GitHub Issue or reach the maintainer at `normanhasibuan@hotmail.com`.
