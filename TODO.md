# Follow-up

- [ ] Add a narrow, static include-graph check for modular shell configuration.
  - Motivation: detect a managed main shell config that references a missing or
    no-longer-managed companion file.
  - First scope: parse only explicitly declared or simple static `source`/`.`
    includes that resolve within the repository-managed config tree; prove
    include reachability and file presence, and report missing includes and
    cycles.
  - Exclusions: do not evaluate shell, expand arbitrary variables, follow
    arbitrary external paths, inspect function bodies, or recursively scan
    arbitrary files.
