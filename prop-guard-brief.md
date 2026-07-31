# Project Brief — Prop Rule Guard

## How to use this document

Do NOT write any code yet. Read this brief, then:
1. Ask me any clarifying questions you need.
2. Propose a project structure and an architecture (modules, data flow, file layout).
3. Propose a build order — what to implement first, second, third.
4. Wait for my approval before writing implementation code.

---

## 1. What this is

A local desktop tool that sits between an algorithmic trading bot (or a manual trader)
and a MetaTrader 5 account, and enforces the rules of a proprietary trading firm
("prop firm") challenge so the account never fails due to a rule violation.

Prop firms sell evaluation accounts (typically $250–$1000 per account). Traders lose
these accounts constantly — usually not because their strategy is unprofitable, but
because they breached a mechanical rule: daily drawdown, max drawdown, lot size limit,
news-trading window, weekend holding, consistency rules.

This tool makes that class of failure impossible.

## 2. The one promise

The product promises exactly one thing:

> "This will not make you profitable. It will make sure your account is never lost
> to a rule violation."

This is important for the architecture and for every string in the UI.
The tool must NEVER claim, imply, or suggest profit, edge, or performance improvement.
No "increase your win rate", no "optimize your trades". It is a safety layer only.

## 3. Scope for version 1 (be strict about this)

IN SCOPE:
- One platform: MetaTrader 5 only.
- One prop firm to start (I will tell you which). But see the rules-engine requirement:
  adding a second firm must be a data change, never a code change.
- Two operating modes (see below).
- Local execution only.

OUT OF SCOPE for v1:
- MT4, cTrader, TradingView, crypto exchanges.
- Any cloud component, user accounts, or hosted dashboard.
- Any trade-generating or strategy logic. This tool never opens a trade for profit
  reasons. It only blocks, closes, or warns.
- Mobile.

## 4. Hard architectural constraint: trust

This is the single most important non-functional requirement.

Everything runs on the user's own machine. Broker credentials, account numbers,
API keys, and trade data must NEVER leave the user's computer. There is no server
that receives account access. There is no "connect your account to our platform" flow.

Reason: the target market is saturated with scams. "Your credentials never leave your
machine" is both a genuine safety property and the core sales argument. Design for it
from the first line — do not add it later.

The only network calls allowed in v1 are:
- License validation (must fail gracefully / allow offline grace period).
- Optionally fetching a rules file update, signed or checksummed.

## 5. Rules as data, not code

Prop firm rules must live in versioned JSON (or similar) rule files — one file per
firm, per account type. The rule engine reads these files. Adding a new prop firm
should take ~10 minutes of writing a config file, with zero changes to the engine.

Rule types that must be expressible in the schema (non-exhaustive — design the schema
to be extensible):
- Max daily loss (absolute and percentage; based on balance or equity; reset time and
  timezone must be configurable — firms differ here and this is a common failure point)
- Max overall drawdown (static vs trailing; end-of-day vs intraday trailing)
- Profit target
- Max lot size / max total exposure / max concurrent positions
- Minimum and maximum trading days
- Consistency rule (no single day may exceed X% of total profit)
- News blackout windows (time-based; economic calendar integration is optional in v1)
- Weekend / holiday holding restrictions
- Minimum stop-loss requirement
- Maximum single-trade risk

The engine must also support a "stricter than required" safety margin: if the firm's
daily loss limit is 5%, the user can configure the tool to enforce 3.5%. This buffer
is a core feature, not an extra.

## 6. Two operating modes

**Monitor mode** — observes only. Never touches an order. Warns, logs, alerts.
This mode exists so a new user can run the tool without granting it any destructive
power. It is the low-trust entry point and matters commercially.

**Guard mode** — actively prevents violations: blocks orders that would breach a rule,
reduces lot size to a compliant level, closes positions when a threshold is approached,
and can halt trading for the rest of the session.

Both modes must produce identical logs, so a user can run monitor mode for a week and
see exactly what guard mode WOULD have done. That report is a sales asset.

## 7. The lock

The user must be able to lock their configured limits so they cannot loosen them in a
moment of emotion. Locks can be time-based (e.g. locked until the challenge ends) or
require deliberate friction to undo. Tightening a limit is always allowed; loosening a
locked limit is not.

This addresses the actual failure mode: the trader who disables their own risk limits
at 2am after three losses.

## 8. Logging — treat this as a first-class feature

Every decision the tool makes is written to an append-only, tamper-evident log:
timestamp, rule evaluated, account state at that moment, decision taken, reason in
plain language.

Two reasons this matters:
- The user needs to trust and audit it.
- The exported log is the marketing proof for the product. It must be clean enough
  to publish.

Also produce a human-readable session report: what happened, what was blocked, how
close the account came to each limit.

## 9. Messages after a loss

After a losing trade or a blocked action, the tool shows a short calm message —
factual and grounding, not hype. ("You are 2.1% from your daily limit. 3 trading days
remain.") These must be togglable and off by default for anything motivational in tone.

## 10. Proof harness (build this alongside the product, not after)

I need verifiable evidence the tool works, without waiting months for a real challenge
outcome. Design a test harness that produces publishable output:

1. **Violation scenario suite** — ~40 synthetic scenarios, each engineered to breach a
   specific rule (consecutive losses, oversized lot, trading during a news window,
   holding over the weekend, crossing the daily drawdown boundary by a fraction).
   Expected result: every scenario is caught. Output as a readable pass/fail table.

2. **Historical replay** — feed a real historical trade log through the engine and
   report how many times the account would have breached rules without the tool,
   versus with it.

3. **Adversarial demo** — run a deliberately aggressive or random strategy on a demo
   account and show that it loses money while never once violating a rule. Losing money
   without breaching is the correct, publishable demonstration.

## 11. Licensing

Include a licensing mechanism from the start (this market pirates everything).
Keep it simple, offline-tolerant, and non-invasive. Do not let it break the "nothing
leaves your machine" promise.

## 12. Distribution

Ships as an installable desktop application for Windows (where MT5 users are).
The user should not need to install Python or set up an environment manually.

## 13. About me and my constraints

- I am a solo developer. Everything must be maintainable by one person.
- I have built an algorithmic trading bot in Python connected to MetaTrader 5, so I
  know this domain well and I am comfortable in Python.
- I previously built a rough version of this idea and abandoned it. This is a clean
  rebuild, not a patch of that code.
- Prefer boring, well-documented, dependency-light choices over clever ones.
- Explain your reasoning as you go — I want to understand the system, not just receive it.

---

## Your first response

Do not write code. Respond with:
- Any questions you need answered before designing.
- A proposed architecture and module breakdown.
- A proposed rule-file schema (a draft example is fine).
- A build order with a realistic first milestone.
