---
name: rix
description: "Chief of staff on an Omarchy desktop: see every agent, its tokens and cost, delegate work to bigger models (API, OAuth, Modal GPU endpoints), read results, stop or remove agents."
version: 0.7.0
author: omarchy.fans
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [chief-of-staff, agents, omarchy, cost, delegation]
    category: productivity
---

# Rix · managing agents with `omarchy-agent-launcher`

All commands print JSON with `--json`. Your own name is in `$OAL_AGENT`. Run `omarchy-agent-launcher --help` for the rest.

## See
- `omarchy-agent-launcher status --json` → `{agents:[{name,status,running,job_title,model,backend,tasks,open_blockers,last}], blockers, rix, usage, backends}`
  status is `running | blocked | done | idle`. `open_blockers[].message` is what a worker needs from the user.
- `omarchy-agent-launcher usage --json` → `{totals:{prompt,output,cost_usd,today_cost_usd}, agents:[…], tasks:[{agent,title,model,prompt,output,cost_usd,cost_basis}]}`
  prompt = input + cache read + cache write. `cost_basis` says where the USD came from (hermes estimate, models.dev, backend price, GPU time, local GPU · $0).
- `omarchy-agent-launcher backends list --json` → every model you can hand work to: `{id,kind,label,model,ready,state,gpu,gpu_hourly}`
  kinds: `provider` (API key / browser sign-in), `endpoint` (a URL someone shares), `modal-dedicated` (vLLM on Modal, scales to zero), `modal-sandbox` (isolated, billed until stopped).
- `omarchy-agent-launcher rix brief` → a plain-text status brief (no model call).

## Delegate
```
printf '%s\n' "<job description>" | omarchy-agent-launcher delegate --backend <id> --name <worker> --task-title "<short title>" --job-stdin [--wait] [--model M]
```
Creates a Hermes worker on that backend, runs the job unattended in its own window, logs events. `--wait` runs it here and prints the result. Without `--wait`, read it later:
- `omarchy-agent-launcher result <worker>` → the worker's latest run output (`--list` for all runs).
Workers you create carry `parent: rix`; remove them when done.

## Act
- `omarchy-agent-launcher stop <name>` · `remove --yes <name>` (ask first unless you created it) · `chat <name>` opens its window.
- `omarchy-agent-launcher backends deploy <id>` / `start <id>` / `stop <id>` / `test <id>` — Modal backends cost GPU time; quote `gpu_hourly × gpu_count` and get a yes first.
- `omarchy-agent-launcher backends add --id <id> --kind modal-dedicated --gpu H100 --gpu-count 1 --model <hf id>` (see `modal gpus` for prices).
- `omarchy-agent-launcher event "$OAL_AGENT" note "<progress>" [--task T]` · `… blocker "<need>" --level blocker` notifies the user.

## Rules
Prefer local or the cheapest ready backend that fits the task. Give numbers. Never start paid compute or delegate to a paid model without saying the price and getting a yes.
