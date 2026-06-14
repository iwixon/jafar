#!/usr/bin/env bash
# Regenerate nix/deps.json — the pinned Gradle dependency lockfile for the
# jfr-mcp Nix build.
#
# Why this wrapper exists: nixpkgs' Gradle `fetchDeps` updater writes the
# regenerated lockfile next to the package's source position. Under a flake the
# package files are copied read-only into /nix/store, so the writeback fails and
# the build pins to a stale source snapshot. Here we build the updater against
# the real working-tree paths (impure) — so both the source and the lockfile
# resolve to this repo — while pinning nixpkgs to the exact rev in flake.lock so
# the Gradle/JDK versions match the sandboxed `nix build` exactly.
set -euo pipefail

# Invoked via `nix run .#update-deps` from the repo root, so $PWD is the repo.
# (BASH_SOURCE can't be used: this script runs from the read-only /nix store.)
repo_root="${1:-$PWD}"
if [ ! -f "$repo_root/nix/jfr-mcp.nix" ]; then
  echo "error: run this from the jafar repo root (got repo_root=$repo_root)" >&2
  exit 1
fi

# Pin nixpkgs to the same rev as flake.lock so the updater's Gradle matches the
# one `nix build` uses. Fetched by narHash → reproducible, no flake.lock churn.
nixpkgs_rev=$(jq -r '.nodes.nixpkgs.locked.rev' "$repo_root/flake.lock")
nixpkgs_hash=$(jq -r '.nodes.nixpkgs.locked.narHash' "$repo_root/flake.lock")

echo "Building deps updater (nixpkgs ${nixpkgs_rev:0:12}, pinned from flake.lock) ..." >&2
updater=$(nix-build --no-out-link --impure --expr "
  let
    nixpkgs = builtins.fetchTarball {
      url = \"https://github.com/NixOS/nixpkgs/archive/${nixpkgs_rev}.tar.gz\";
      sha256 = \"${nixpkgs_hash}\";
    };
    pkgs = import nixpkgs { };
  in (pkgs.callPackage ${repo_root}/nix/jfr-mcp.nix {
    # Build from the live working tree, and write the lockfile straight back
    # into the repo (not a read-only store snapshot).
    srcTree = ${repo_root};
    depsData = ${repo_root}/nix/deps.json;
  }).mitmCache.updateScript
")

echo "Running updater — this performs a full Gradle build through a recording proxy ..." >&2
exec "$updater"
