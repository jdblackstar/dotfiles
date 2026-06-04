---
name: map
description: Synced relay command. Use when the user asks to run the map workflow.
---
You are analyzing a codebase to build a developer mental model —
enough to "hold the system in your head."

Do NOT summarize every file. Focus on architecture and critical paths.

First, assess repo size and complexity. For small projects (<20 files),
be more thorough. For large codebases, ruthlessly prioritize.

Steps:

1. Identify system entrypoints
   CLI commands, server routes, main functions, workers, scheduled tasks

2. Identify core modules
   Domain logic, service layer, persistence, external integrations

3. Trace 1–3 primary execution paths (the actions that justify this
   system's existence)
   entrypoint → validation → domain logic → persistence → side effects → response

4. Identify key data structures and where they are defined

5. Identify configuration surfaces
   Env vars, feature flags, config files that change behavior without code changes

6. Map system boundaries
   What this system owns vs. delegates to external services

Output format:

SYSTEM OVERVIEW
2–3 paragraphs on what the system does and why it exists.

ENTRYPOINTS
file:path → responsibility

CORE MODULES
module → role in system

PRIMARY FLOWS
Step-by-step call paths for the 1–3 most important actions.

KEY TYPES / STRUCTURES
Important models, where they live, and invariants they encode
(e.g. "this enum must stay in sync with the DB migration").

SYSTEM BOUNDARIES
What is owned vs. called out to. External dependencies and their
failure modes. API contracts exposed or consumed.

CHANGE HOTSPOTS
High coupling, implicit dependencies, missing tests, or areas where
changes are likely to cascade.