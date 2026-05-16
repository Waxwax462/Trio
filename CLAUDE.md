# Ruflo — Claude Code Configuration

## Rules

- Do what has been asked; nothing more, nothing less
- NEVER create files unless absolutely necessary — prefer editing existing files
- NEVER create documentation files unless explicitly requested
- NEVER save working files or tests to root — use `/src`, `/tests`, `/docs`, `/config`, `/scripts`
- ALWAYS read a file before editing it
- NEVER commit secrets, credentials, or .env files
- Keep files under 500 lines
- Validate input at system boundaries

## Agent Comms (SendMessage-First Coordination)

Named agents coordinate via `SendMessage`, not polling or shared state.

```
Lead (you) ←→ architect ←→ developer ←→ tester ←→ reviewer
              (named agents message each other directly)
```

### Spawning a Coordinated Team

```javascript
// ALL agents in ONE message, each knows WHO to message next
Agent({ prompt: "Research the codebase. SendMessage findings to 'architect'.",
  subagent_type: "researcher", name: "researcher", run_in_background: true })
Agent({ prompt: "Wait for 'researcher'. Design solution. SendMessage to 'coder'.",
  subagent_type: "system-architect", name: "architect", run_in_background: true })
Agent({ prompt: "Wait for 'architect'. Implement it. SendMessage to 'tester'.",
  subagent_type: "coder", name: "coder", run_in_background: true })
Agent({ prompt: "Wait for 'coder'. Write tests. SendMessage results to 'reviewer'.",
  subagent_type: "tester", name: "tester", run_in_background: true })
Agent({ prompt: "Wait for 'tester'. Review code quality and security.",
  subagent_type: "reviewer", name: "reviewer", run_in_background: true })

// Kick off the pipeline
SendMessage({ to: "researcher", summary: "Start", message: "[task context]" })
```

### Patterns

| Pattern | Flow | Use When |
|---------|------|----------|
| **Pipeline** | A → B → C → D | Sequential dependencies (feature dev) |
| **Fan-out** | Lead → A, B, C → Lead | Independent parallel work (research) |
| **Supervisor** | Lead ↔ workers | Ongoing coordination (complex refactor) |

### Rules

- ALWAYS name agents — `name: "role"` makes them addressable
- ALWAYS include comms instructions in prompts — who to message, what to send
- Spawn ALL agents in ONE message with `run_in_background: true`
- After spawning: STOP, tell user what's running, wait for results
- NEVER poll status — agents message back or complete automatically

## Swarm & Routing

### Config
- **Topology**: hierarchical-mesh (anti-drift)
- **Max Agents**: 5
- **Memory**: hybrid
- **HNSW**: Enabled
- **Neural**: Enabled

```bash
npx @claude-flow/cli@latest swarm init --topology hierarchical --max-agents 8 --strategy specialized
```

### Mandatory Swarm Pipeline (ALL coding tasks)

**Every coding task — no exceptions — MUST be handled by this 5-agent pipeline:**

```
architect → coder → tester → reviewer → security-auditor
```

| Agent | subagent_type | Responsibility |
|-------|--------------|----------------|
| `architect` | `system-architect` | Design, file plan, interface contracts |
| `coder` | `coder` | Implementation — waits for architect |
| `tester` | `tester` | Tests — waits for coder |
| `reviewer` | `reviewer` | Code quality + correctness — waits for tester |
| `security-auditor` | `security-auditor` | Security review — waits for reviewer |

**Spawn template (copy-adapt for every task):**
```javascript
// Spawn all 5 in ONE message, all run_in_background: true
Agent({ subagent_type: "system-architect", name: "architect", run_in_background: true,
  prompt: "Design: [task]. SendMessage findings+plan to 'coder'." })
Agent({ subagent_type: "coder", name: "coder", run_in_background: true,
  prompt: "Wait for 'architect'. Implement. SendMessage to 'tester'." })
Agent({ subagent_type: "tester", name: "tester", run_in_background: true,
  prompt: "Wait for 'coder'. Write/run tests. SendMessage to 'reviewer'." })
Agent({ subagent_type: "reviewer", name: "reviewer", run_in_background: true,
  prompt: "Wait for 'tester'. Review quality. SendMessage to 'security-auditor'." })
Agent({ subagent_type: "security-auditor", name: "security-auditor", run_in_background: true,
  prompt: "Wait for 'reviewer'. Security audit. Report findings back." })
SendMessage({ to: "architect", message: "[full task context]" })
```

### When to Swarm
- **ALL coding tasks**: bug fixes, features, refactors, performance, security — always 5-agent pipeline
- **Skip swarm only for**: questions, explanations, config-only changes (1 key/value), docs-only edits

### 3-Tier Model Routing

| Tier | Handler | Use Cases |
|------|---------|-----------|
| 1 | Agent Booster (WASM) | Simple transforms — skip LLM, use Edit directly |
| 2 | Haiku | Simple tasks, low complexity |
| 3 | Sonnet/Opus | Architecture, security, complex reasoning |

## Memory & Learning

### Before Any Task
```bash
npx @claude-flow/cli@latest memory search --query "[task keywords]" --namespace patterns
npx @claude-flow/cli@latest hooks route --task "[task description]"
```

### After Success
```bash
npx @claude-flow/cli@latest memory store --namespace patterns --key "[name]" --value "[what worked]"
npx @claude-flow/cli@latest hooks post-task --task-id "[id]" --success true --store-results true
```

### MCP Tools (use `ToolSearch("keyword")` to discover)

| Category | Key Tools |
|----------|-----------|
| **Memory** | `memory_store`, `memory_search`, `memory_search_unified` |
| **Bridge** | `memory_import_claude`, `memory_bridge_status` |
| **Swarm** | `swarm_init`, `swarm_status`, `swarm_health` |
| **Agents** | `agent_spawn`, `agent_list`, `agent_status` |
| **Hooks** | `hooks_route`, `hooks_post-task`, `hooks_worker-dispatch` |
| **Security** | `aidefence_scan`, `aidefence_is_safe`, `aidefence_has_pii` |
| **Hive-Mind** | `hive-mind_init`, `hive-mind_consensus`, `hive-mind_spawn` |

### Background Workers

| Worker | When |
|--------|------|
| `audit` | After security changes |
| `optimize` | After performance work |
| `testgaps` | After adding features |
| `map` | Every 5+ file changes |
| `document` | After API changes |

```bash
npx @claude-flow/cli@latest hooks worker dispatch --trigger audit
```

## Agents

**Core**: `coder`, `reviewer`, `tester`, `planner`, `researcher`
**Architecture**: `system-architect`, `backend-dev`, `mobile-dev`
**Security**: `security-architect`, `security-auditor`
**Performance**: `performance-engineer`, `perf-analyzer`
**Coordination**: `hierarchical-coordinator`, `mesh-coordinator`, `adaptive-coordinator`
**GitHub**: `pr-manager`, `code-review-swarm`, `issue-tracker`, `release-manager`

Any string works as a custom agent type.

## Build & Test

- ALWAYS run tests after code changes
- ALWAYS verify build succeeds before committing

```bash
npm run build && npm test
```

## CLI Quick Reference

```bash
npx @claude-flow/cli@latest init --wizard           # Setup
npx @claude-flow/cli@latest swarm init --v3-mode     # Start swarm
npx @claude-flow/cli@latest memory search --query "" # Vector search
npx @claude-flow/cli@latest hooks route --task ""    # Route to agent
npx @claude-flow/cli@latest doctor --fix             # Diagnostics
npx @claude-flow/cli@latest security scan            # Security scan
npx @claude-flow/cli@latest performance benchmark    # Benchmarks
```

26 commands, 140+ subcommands. Use `--help` on any command for details.

## Setup

```bash
claude mcp add claude-flow -- npx -y @claude-flow/cli@latest
npx @claude-flow/cli@latest daemon start
npx @claude-flow/cli@latest doctor --fix
```

**Agent tool** handles execution (agents, files, code, git). **MCP tools** handle coordination (swarm, memory, hooks). **CLI** is the same via Bash.
# CLAUDE.md — Project Rheos (Flow) AID App

> Context file for Claude Code / future development sessions.
> This document describes the feature set of an experimental Automated Insulin Delivery (AID) app inspired by Project Rheos by Jonathan Fitch (Glucosense). Use it as a development reference / spec sheet.

---

## ⚠️ Important Disclaimers

- This is a **personal / research project**, NOT a medical device.
- Insulin dosing software can cause **serious harm or death** if it malfunctions.
- Do **not** "vibe-code" insulin dosing logic. All algorithm code requires deterministic implementation, unit tests, and pressure testing.
- The original Rheos is used by exactly one person (its developer) under self-experimentation.
- For real-world use, FDA / CE / BfArM clearance and clinical studies would be required.
- This file is for **educational and prototyping purposes only**.

---

## 1. Project Overview

**Name:** Rheos (Greek: ῥέος, "flow")
**Type:** Closed-loop / Automated Insulin Delivery (AID) system
**Platform target:** iOS (primary), with potential Apple Watch + widget support
**Inspiration sources:**
- Glucosense IP (glucose score, holistic management algorithms)
- Open-source looping (Trio, DIY Loop) — for pump/CGM communication patterns only

**Differentiators vs. existing pumps (Omnipod 5, Tandem, Medtronic, Trio):**
- Biometric-driven dosing (heart rate, stress, sleep, caffeine)
- Near settings-free onboarding — algorithm self-learns
- Conversational LLM as the primary user interface
- Multi-modal meal logging (photo / voice / text)

---

## 2. Core Design Philosophy

1. **Show only what the user needs.** Hide complexity in the background.
2. **Settings-free, but not guardrail-free.** The algorithm learns; safety bounds are hard-coded.
3. **Context > extrapolation.** Predict using history + current biometrics, not just CGM trend.
4. **Build for today's insulin pharmacokinetics.** Don't assume faster insulins will exist soon (15 min onset, 1 h peak, 3–4 h duration).
5. **Low friction.** Minimal taps per day; widget / chat / voice as primary entry points.

---

## 3. Feature Set

### 3.1 Onboarding
- Inputs: age, weight, height, muscle mass.
- Optional: photo of user → AI body-fat estimation.
- Optional: GLP-1 medication flag (e.g., Tirzepatide) → reduces starting insulin estimate.
- Starting Total Daily Dose (TDD) computed from published clinical equations.
- No carb ratio / ISF / basal entry required at start.

### 3.2 Adaptive Algorithm
- Learns **per-hour insulin sensitivity factor** over ~30 days of data.
- Continuously updates carb ratios and basal rates as physiology shifts.
- Supports **negative basal rates** (suspension) when needed.
- Hard-coded safety guardrails around all learned parameters.
- Prediction model uses: prior CGM data + biometrics + meal context + historical patterns from similar past situations.

### 3.3 Biometric-Driven Dosing
**Inputs (via wearable APIs):**
- Heart rate — second-level resolution; HRV.
- Sleep — duration + quality.
- Recovery / readiness scores (Whoop, Aura).
- Step count / activity classification.

**Behaviors:**
- Detects exercise via HR rise + motion → automatic temp target + basal reduction.
- Detects stress (e.g., presentations, illness onset) → adjusts insulin resistance estimate.
- **Stress chart** rendered in UI as derivative of HR.
- Live HR feed at top of screen.

### 3.4 Caffeine Tracking
- User logs caffeine intake (mg or drink type).
- Uses caffeine half-life (~5–6 h biological, with extended insulin-resistance effects up to 12 h).
- Feeds into insulin sensitivity estimate.

### 3.5 Meal Logging (Multi-Modal)
**Three input methods, all routed through an AI estimator:**
1. **Photo** — image classifier estimates carbs / protein / fat / fiber.
2. **Voice** — speech-to-text → LLM parses ("short rib pasta and asparagus").
3. **Text** — free-form description or simple carb number ("50g carbs").

**Output:** estimated macros + recommended bolus. Algorithm tolerates ±10–20 % macro error and corrects via basal in the following hours.

**Macro-based extended bolus:** protein, fat, and fiber extend dosing windows over multiple hours, rather than dosing all carbs upfront.

### 3.6 Conversational LLM Interface
- Free-form chat about glucose, settings, plans, history.
- **Action-capable:** can apply settings changes / temp targets after user confirmation.
  - Example: *"I'm about to run 5 miles in 30 min — how should I prepare?"* → proposes temp target 120 mg/dL, basal reduction → user taps **Activate**.
- **Dynamic chart rendering** in chat: AGP, weekly insulin use, time-in-range trends.
- Important architecture note: **LLM is the messenger, not the brain.**
  - All dosing logic, predictions, statistics → deterministic code.
  - LLM only handles natural-language I/O and chart selection.

### 3.7 Reflections Tab
- Daily / weekly / monthly retrospectives.
- Identifies recurring patterns (e.g., 4 a.m. spikes after Mexican food).
- Highlights wins, challenges, learning opportunities.
- Optional **Analyze** button (every 7 or 30 days) → reviews settings, suggests tweaks. Becoming less relevant as algorithm self-tunes.

### 3.8 Sick Day Mode
- Manual toggle.
- Expands aggressiveness of safeguards (higher basal allowances, more aggressive corrections).
- Useful when illness-driven insulin resistance overwhelms normal guardrails.

### 3.9 Convenience Surfaces
- Home-screen widget for quick logging without opening the app.
- (Future) Apple Watch app — bolus + carb +/- buttons.
- (Future) SMS interface via Twilio — text the pump as if it were a contact.

---

## 4. Technical Architecture (Suggested)

### Data Layer
- CGM: Dexcom G7 / Eversense (BLE).
- Pump: Omnipod (BLE Dash protocol) — note: open-source decoded protocol, FDA implications for production.
- Wearables: Whoop, Aura, Apple HealthKit (iOS), Google Health Connect (Android future).
- Local persistent store: SwiftData / Core Data; encrypted.

### Algorithm Layer (deterministic, NOT LLM)
- Glucose prediction model.
- Per-hour ISF / carb ratio learner (rolling 30-day window).
- Biometric-modifier module (HR → resistance scalar).
- Caffeine half-life model.
- Meal-extension model (macro → multi-hour insulin curve).
- Hard safety guardrails (max basal, max bolus, suspension thresholds).

### AI / LLM Layer (translation only)
- Vision model: meal photo → macro estimates.
- LLM (e.g., Claude / GPT) for: chat, voice parsing, chart selection, plan suggestion.
- All LLM-suggested actions must require **explicit user confirmation** before being applied.
- LLM never directly modifies insulin delivery.

### UI Layer
- SwiftUI (iOS).
- Live HR + stress chart at top.
- Chat-first interaction model.
- Reflections / charts / settings as secondary tabs.

---

## 5. Integrations Checklist

| System | Purpose | Notes |
|---|---|---|
| Dexcom CGM | Glucose data | BLE, official API where possible |
| Omnipod | Insulin delivery | BLE; review legal posture |
| Whoop API | HR, sleep, recovery, stress | OAuth |
| Aura API | HR, sleep, readiness | OAuth |
| Apple HealthKit | HR, steps, sleep fallback | Native |
| OpenAI / Anthropic API | Chat + vision | Privacy: avoid sending PHI without consent |
| Twilio (future) | SMS interface | Optional |

---

## 6. Safety & Compliance

- All dosing decisions: deterministic code, unit-tested, with property-based tests for edge cases.
- LLM output must never bypass safety guardrails.
- Maximum bolus / basal caps configurable, but with hard ceiling.
- Logging & audit trail for every dose, override, and setting change.
- Fail-safe defaults: when in doubt, suspend delivery, alert user.
- Battery / Bluetooth / connectivity loss handling.
- **Regulatory:** Not for clinical use without FDA / CE / BfArM clearance (EU users, including DE: MDR class IIb minimum likely).

---

## 7. Development Roadmap (Suggested)

1. **Phase 1 — Read-only loop**
   - Connect CGM + wearable; visualize HR, stress, glucose. No dosing.
2. **Phase 2 — Manual logging + recommendations**
   - Meal logging (text + photo). Recommended-only dosing; user manually doses on existing pump.
3. **Phase 3 — Closed-loop simulation**
   - Run algorithm in shadow mode; compare to actual pump decisions; tune.
4. **Phase 4 — Self-experimentation only**
   - Per-user, opt-in, single-user closed loop. Heavy logging.
5. **Phase 5 — Regulatory pathway / partnership**
   - Engage with pump manufacturer or notified body (in DE: e.g., TÜV SÜD).

---

## 8. Open Questions / Research Needed

- Optimal weighting of HR-derived stress vs. CGM trend in dosing decisions.
- Sick-day algorithm: how to hold a steady ~110 mg/dL during illness (Jonathan's open question — may not be fully tractable).
- Meal auto-detection from CGM curve alone (true closed loop without logging).
- Wearable selection robustness — what if user has no wearable?

---

## 9. References & Inspiration

- Project Rheos / Glucosense — Jonathan Fitch (podcast interview source for this spec).
- Trio (open-source AID).
- DIY Loop.
- Whoop / Aura published methods on HR-derived stress.
- Published TDD / ISF estimation equations (Beta Bionics, ADA guidelines).

---

*Last updated: 2026-05-10*
*Source: Diabetech podcast interview with Jonathan Fitch, "This AID Algorithm Reads Your Body — Inside Project Rheos"*

