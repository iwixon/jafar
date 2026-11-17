# Building jfr-mcp with Nix

This repo ships a local Nix flake that builds the **jfr-mcp** MCP server fully
inside a Nix derivation — no shared `~/.gradle`, no Gradle daemon, no host
`~/.m2`. Dependencies are pinned by hash in `nix/deps.json` and resolved offline
in the build sandbox, so rebuilds are reliable and repeatable.

The Nix files live on the **`nix-build`** branch (kept off `main` so `main`
stays clean for upstream pulls):

| File | Purpose |
|------|---------|
| `flake.nix` | Outputs: `packages.jfr-mcp`, `apps.jfr-mcp`, `apps.update-deps` |
| `nix/jfr-mcp.nix` | The derivation. `gradle_9` overridden with JDK 8 / 21 / 25 toolchains; builds `:jfr-mcp:shadowJar` into a wrapped `jfr-mcp` binary |
| `nix/deps.json` | Pinned Gradle dependency lockfile (hash-verified) |
| `nix/no-maven-local.init.gradle` | Strips `mavenLocal()` so deps resolve via the lockfile, not the host `~/.m2` |
| `nix/update-deps.sh` | Regenerates `nix/deps.json` against the working tree |

> All commands below run from the repo root (`~/git/jafar`) on the `nix-build`
> branch unless noted.

---

## TL;DR

```bash
# 1. Build locally and smoke-test
nix build .#jfr-mcp
./result/bin/jfr-mcp --stdio   # Ctrl-C to stop

# 2. If you changed dependencies, refresh the lockfile first:
nix run .#update-deps
git add nix/deps.json && git commit -m "Update Gradle deps lockfile"

# 3. Push the new build to your shell (see "Reinstall on your machine")
```

---

## When do I need to regenerate `nix/deps.json`?

`nix build` is **offline** — it only sees the artifacts already pinned in
`nix/deps.json`. Regenerate the lockfile **only when the set of Gradle
dependencies changes**, e.g.:

- a `build.gradle` / `settings.gradle` adds, removes, or bumps a dependency or plugin
- the Gradle wrapper version changes
- an upstream pull touches any of the above

You do **not** need to regenerate it for ordinary Java source changes.

**Symptom that you forgot:** `nix build` fails with
`Could not find <group>:<artifact>:<version>` and a `Searched in the following
locations:` list. That means the offline build wants an artifact the lockfile
doesn't have — run `nix run .#update-deps`.

### Regenerate the lockfile

```bash
nix run .#update-deps          # full Gradle build through a recording proxy (~1 min)
git add nix/deps.json
git commit -m "Update Gradle deps lockfile"
```

This performs one real (online) Gradle build, records every artifact it fetches,
and rewrites `nix/deps.json`. It writes straight back into the working tree.

---

## Make a code change

For plain source edits (no dependency changes):

```bash
git add -A && git commit -m "..."   # commit your change
nix build .#jfr-mcp                 # rebuild offline from the existing lockfile
./result/bin/jfr-mcp --stdio        # smoke-test
```

`nix build` reads the **committed** tree of the `nix-build` branch (the flake is
a `git+file` input), so commit before you expect a change to show up in a
rebuild driven through the nix-darwin flake. A bare `nix build .#jfr-mcp` from
the repo also picks up the dirty working tree, which is handy while iterating.

---

## Pull from upstream

`main` tracks upstream `btraceio/jafar`; `nix-build` carries the Nix files on top.

```bash
git checkout main
git pull                       # fast-forward main from upstream

git checkout nix-build
git rebase main                # replay the Nix commit(s) onto the new main
                               # (or: git merge main)

# If dependencies changed upstream, refresh the lockfile:
nix run .#update-deps
git add nix/deps.json && git commit -m "Update Gradle deps lockfile"

# Verify the build still works:
nix build .#jfr-mcp
```

---

## Reinstall on your machine (nix-darwin)

`jfr-mcp` reaches your shell through nix-darwin, which pins the `jafar` flake
input to a specific commit on `nix-build`. After committing new work here, bump
that pin and rebuild:

```bash
cd /path/to/nix-darwin
nix flake lock --update-input jafar          # re-pin to the latest nix-build commit
sudo darwin-rebuild switch --flake .#HOSTNAME
```

Then confirm:

```bash
which jfr-mcp                                 # -> /run/current-system/sw/bin/jfr-mcp
jfr-mcp --stdio                               # Ctrl-C to stop
```

> The nix-darwin `jafar` input is `git+file:///path/to/jafar?ref=nix-build`,
> so it always pins a **committed** revision of `nix-build` — uncommitted changes
> here are invisible to `darwin-rebuild`. Commit, then `--update-input jafar`.

---

## Run / register the server

```bash
jfr-mcp --stdio          # STDIO mode (Claude Desktop / Claude Code)
jfr-mcp                  # HTTP mode on port 3000

# Register with Claude Code:
claude mcp add jafar -- jfr-mcp --stdio
```

---

## How the hermetic build works (for the curious)

`nix/jfr-mcp.nix` uses nixpkgs' Gradle **mitm-cache** mechanism:

1. **Record** (`nix run .#update-deps`): runs one real Gradle build with a proxy
   that intercepts every HTTP fetch, then writes the URLs + SHA-256 hashes to
   `nix/deps.json`. `mavenLocal()` is stripped (via the init script) so nothing
   sneaks in from the host `~/.m2`, and parallelism/caching are disabled so the
   recording is complete and deterministic.
2. **Build** (`nix build`): runs Gradle in the Nix sandbox with **no network**.
   A local proxy serves exactly the artifacts in `nix/deps.json`, verified by
   hash. Anything not in the lockfile fails the build (hence the regenerate
   step above).

The build needs three JDKs because the modules target different bytecode levels
(parser/tools → 8, plugin/processor/demo → 21, shell/MCP → 25). The derivation
feeds `gradle_9` all three toolchains explicitly so the sandboxed build never
tries to provision a JDK.
