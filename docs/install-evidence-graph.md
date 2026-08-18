# Installation evidence graph

`./install-evidence` is an experimental, developer-facing explanation tool. It
connects tracked profile and package intent to sanitized read-only observations
and then applies named inference rules. It never installs, updates, repairs, or
otherwise changes the machine.

The first vertical slice deliberately stays close to
`tests/verify-mac-install.sh`:

- all 20 granular verifier calls are discovered from the verifier source rather
  than maintained as a second check list;
- profile composition comes from the selected `profiles/*.sh` file, parsed with
  a strict non-evaluating grammar;
- selected platform manifests are parsed as data, with source lines preserved;
- the two install markers, seven managed links, nine verifier commands, Oh My
  Zsh applicability, and TPM `.git` directory are mapped end to end;
- package-to-command provenance is added for `curl`, `eza`, `fzf`, `git`,
  `neovim`/`nvim`, `ripgrep`/`rg`, `starship`, `tmux`, and `zoxide` when those
  packages are declared by the selected platform/profile;
- `1password` and `cursor` are representative personal-only declarations that
  remain explicitly unverified in this slice; and
- a required `installation healthy` claim is derived without allowing optional
  coverage gaps to hide lower-level failures.

The existing verifier remains unchanged. The adapter intentionally requires the
expected verifier surface (2 marker checks, 7 links, 9 commands, 1 directory,
and 1 Git directory). If that surface changes, graph discovery fails loudly so
the mapping must be reviewed.

## Public-repository privacy boundary

This repository is public. Tracked fixtures must be synthetic, and real live
reports must never be committed. `.install-evidence/` is ignored for temporary
local reports:

```sh
mkdir -p .install-evidence
./install-evidence --live --profile personal --format json \
  >.install-evidence/report.json
```

Even local output is public-safe by default. The collector may inspect a raw
value long enough to compare it, but discards it before graph construction:

- marker contents become only `matched` or `mismatched`;
- command paths become only `allowed` or `unexpected`;
- symlink targets become `matched`, or `mismatched` with only a coarse scope
  such as `installed_repo`, `home`, `external`, or `relative`;
- probe failures become a fixed error code such as `permission_denied`; and
- home, installed-checkout, source-worktree, usernames, hostnames, environment
  variables, arbitrary filenames, file contents, and raw OS error strings are
  never serialized.

Tracked source locations are retained as repository-relative path and line
number; declaration text itself is not copied into reports. The selected
profile, platform, and collection timestamp remain explicit report context
required by the schema; this is why a real report is still a local artifact
rather than something to commit.

JSON marks this explicitly as `distribution: "local_only"`, and terminal
summaries repeat the do-not-commit warning.

## Architecture

The command uses only the Python 3 standard library and keeps each stage
explicit:

- `intent.py` strictly parses profile, platform, manifest, installer, and
  verifier declarations without sourcing them;
- `ProbeDefinition` values describe the fixed observation allowlist;
- `probes.py` either executes those definitions read-only or replays inert
  fixture facts;
- `_infer_observation` applies one named rule to facts without changing them;
- `assemble_document` creates claim/evidence nodes, propagation edges, and the
  versioned document;
- `cli.py` performs deterministic JSON serialization; and
- `render.py` produces the concise terminal explanation or dependency-free DOT.

## Commands

Fixture replay is the normal development path:

```sh
./install-evidence \
  --fixture tests/fixtures/install-evidence/healthy-personal-macos.json
```

Live collection is explicit:

```sh
./install-evidence --live --profile personal
```

Output formats are:

```sh
./install-evidence --fixture FIXTURE --format summary
./install-evidence --fixture FIXTURE --format json
./install-evidence --fixture FIXTURE --format dot
```

The summary exits `0` when all applicable required claims are proven, `1` when
a required claim failed or conflicted, `2` when required evidence is unknown or
skipped, and `64` for invalid input or unsupported repository intent. Optional
unverified package declarations do not change the required health exit code.

`./install-evidence --list-probes --profile personal --platform macos` lists
the exact live definitions without collecting any evidence.

## Claim and evidence model

A claim is an inference such as “`~/.zshrc` targets the managed source.”
Evidence is an immutable fact used by a named rule:

- tracked-source evidence records only the repository-relative path and line;
- observation evidence records one sanitized probe outcome;
- claims record a state, rule name, explanation, and evidence IDs; and
- the health claim records `blocked_by` edges to every required failed,
  conflicted, unknown, or skipped prerequisite.

The graph uses these relations:

- `profile_includes`: profile to selected platform manifest;
- `applies_on`: selected profile to tracked platform intent;
- `declares`: manifest to package entry;
- `installs`: package entry to the command claim it supports;
- `requires`: profile or package to a claim;
- `proven_by`: intent or claim to source/observation evidence; and
- `blocked_by`: higher-level health claim to an unresolved prerequisite.

For example:

```text
personal profile
  -> profile_includes packages/brew/base.Brewfile
  -> declares brew "ripgrep" (line 15)
  -> installs "command rg resolves as expected"
  -> proven_by command.rg observation (resolution: allowed)
  -> command_resolution_allowed => proven
  -> contributes to personal/macos installation healthy
```

A failure retains the same chain and adds:

```text
installation healthy
  -> blocked_by command rg resolves as expected
  -> unexpected_command_resolution (exact path discarded)
```

## State semantics

- `proven`: observation matches the tracked expectation under the named rule.
- `failed`: direct evidence contradicts a required expectation, including a
  missing item, wrong path type, wrong symlink target, marker mismatch, or
  command resolving outside the allowed platform roots.
- `unknown`: no observation exists or a probe errored. Permission denial is
  unknown, never proof of absence.
- `skipped`: collection explicitly records that an otherwise applicable probe
  was not run.
- `not_applicable`: profile/platform intent says the check does not apply.
- `conflicted`: two or more observations for the same probe disagree.

The health rule is:

1. any required `failed` or `conflicted` claim makes health `failed`;
2. otherwise, any required `unknown` or `skipped` claim makes health `unknown`;
3. otherwise, all applicable required claims are proven and health is `proven`.

Optional coverage claims remain visible in counts and explanations but do not
block required health.

## JSON schema

The stable JSON document currently uses `schema_version: "1.1.0"` and contains:

- `collection`: mode, timestamp, profile, platform, prefix-sanitization tokens,
  and machine-readable public-safe privacy guarantees;
- `summary`: health state, state counts, mapped verifier-check count, and
  selected manifest declaration count;
- `claims`: deterministically ordered states, rules, explanations, source
  locations, evidence IDs, and health blockers;
- `evidence`: deterministically ordered tracked-source and observation facts;
  and
- `graph`: deterministically ordered nodes and typed directed edges.

Keys are emitted in sorted order. Fixture timestamps are supplied by the
fixture, so identical fixture runs produce byte-identical JSON. Live timestamps
are UTC collection time.

Raw host paths are not serialized at all. The `<home>`, `<repo>`, and
`<source-repo>` tokens describe the tracked intent vocabulary; observation
evidence contains only classified comparisons, scopes, resolutions, and fixed
error codes.

## Read-only live boundary

Live mode executes no subprocesses. Its complete allowlist is:

1. `lstat` on exact marker, verifier, or TPM paths declared by the repository;
2. `readlink` on exact verifier-declared managed links;
3. a bounded read of at most 256 bytes from the two exact marker files;
4. directory/type checks for Oh My Zsh and TPM `.git`; and
5. `PATH` resolution with `shutil.which`; the resolved command is never run.

Destination probes must be rooted at `$HOME`; expected source paths must be
rooted at the explicitly selected installed checkout. `..`, arbitrary absolute
probe paths, shell evaluation, globs, home-directory traversal, and
fixture-defined commands are not supported.

No Homebrew command is run. In particular, the tool does not call `brew
update`, `brew bundle`, `brew bundle dump`, `brew list`, or any installer. It
does not invoke the existing verifier as a single opaque fact; it retains every
granular observation.

Command-resolution rules currently allow:

- macOS package commands under `/opt/homebrew/bin` or `/usr/local/bin`;
- macOS `git` and `curl` additionally under `/usr/bin` or `/bin`; and
- Linux commands under `/usr/bin`, `/bin`, `/usr/local/bin`, or `/snap/bin`.

A command found elsewhere is present but fails with
`unexpected_command_resolution`, making shadowing visible without retaining
where it resolved.

## Fixture format and safety

Fixtures are versioned observation data:

```json
{
  "fixture_version": "2",
  "profile": "personal",
  "platform": "macos",
  "collected_at": "2000-01-01T00:00:00Z",
  "observations": {
    "command.rg": {
      "status": "present",
      "resolution": "allowed"
    },
    "symlink.zshrc": {
      "status": "symlink",
      "comparison": "matched"
    }
  }
}
```

An observation may be an object or a list of objects; any disagreeing facts
produce `conflicted`, even if both observations report `present`. The loader
rejects unknown probe IDs, keys, statuses, classifications, control characters,
raw path/target fields, and free-form error strings. Fixture strings are never
evaluated or used to define a filesystem probe.

Tracked healthy examples live in
`tests/fixtures/install-evidence/healthy-personal-macos.json` and
`healthy-personal-linux.json`. Tests derive missing, wrong-target, unexpected
resolution, skipped, permission-error, conflicting, malicious, raw-path, and
privacy-leak cases from those fixtures.

## Adding a check

1. Add or change the authoritative granular check in
   `tests/verify-mac-install.sh`, preserving read-only behavior.
2. If the installer owns the expectation, make sure the corresponding
   `install.sh` declaration is explicit.
3. Extend the strict adapter in `tools/install_evidence/intent.py` only for the
   new supported syntax; never source or evaluate profile/verifier code.
4. Add a fixed `ProbeDefinition` in `tools/install_evidence/graph.py`.
5. Implement its observation only inside the allowlisted executor in
   `tools/install_evidence/probes.py`, keeping facts separate from inference.
6. Add healthy, negative, error, applicability, deterministic-serialization,
   and explanation tests in `tests/install_evidence.bats`.
7. Update this document's mapped and deliberately unmapped coverage.

## What this graph does not prove

This slice does not inspect Homebrew receipts, package versions, GUI application
bundles, VS Code extensions, taps, macOS defaults, shell behavior, config file
contents, Git remote state, local identity files, signing/SSH agents, SSO, or
whether Oh My Zsh/TPM contain the expected revision. It does not yet map the
verifier's optional local-identity warning. A correct link proves only that its
target matched the expected target during collection; the target itself is
discarded, and the graph does not prove the semantic correctness or secrecy of
the target content.

`installation healthy` therefore means that all required checks mapped by this
version are proven. It is not a claim that every manifest declaration or every
manual/environment-specific setup step is healthy.

The graph is explanation only. It never repairs the machine.
