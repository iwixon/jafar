{
  lib,
  stdenv,
  gradle_9,
  zulu8,
  jdk21,
  jdk25,
  makeWrapper,

  # Source tree to build. Defaults to the repo this file lives in (resolved
  # relative to the store copy under a flake). The deps updater overrides this
  # with the real working-tree path so it isn't pinned to a store snapshot.
  srcTree ? null,

  # Path to the Gradle dependency lockfile. Must be a *path* value:
  #  - under `nix build`, the in-tree `./deps.json` resolves to a store path and
  #    is read at eval time;
  #  - the updater overrides it with the absolute working-tree path so the
  #    regenerated lockfile is written straight back into the repo.
  depsData ? ./deps.json,
}:

# The Jafar build mixes JDK toolchains: parser/tools target Java 8, the gradle
# plugin / processor / demo target 21, and the shell + MCP modules target 25.
# Gradle's toolchain auto-detection is fed these JDKs explicitly so the sandboxed
# (network-less) build can resolve every `JavaLanguageVersion.of(...)` declared
# across the modules without trying to provision a JDK at build time.
let
  gradle = gradle_9.override {
    java = jdk25; # JDK that runs Gradle itself
    javaToolchains = [
      zulu8
      jdk21
      jdk25
    ];
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "jfr-mcp";
  version = "0.26.0-SNAPSHOT";

  # Build straight from the repo working tree this flake lives in.
  src =
    let
      root = if srcTree != null then srcTree else ../.;
      # Root-anchored excludes only: keep the source closure small and
      # deterministic without clobbering same-named directories deeper in the
      # tree (e.g. the `io.jafar.mcp.result` package must survive a top-level
      # `result` symlink exclusion).
      rootExcludes = map (p: toString root + "/" + p) [
        ".git"
        ".gradle"
        ".gradle-home"
        "result"
        "nix"
      ];
    in
    lib.cleanSourceWith {
      src = root;
      filter =
        path: type:
        let
          base = baseNameOf path;
        in
        !(builtins.elem path rootExcludes)
        # Drop Gradle build output directories at any depth.
        && !(type == "directory" && base == "build")
        # Drop the Gradle daemon/cache dir at any depth.
        && base != ".gradle";
    };

  nativeBuildInputs = [
    gradle
    makeWrapper
  ];

  # Pinned Gradle dependency lockfile. Regenerate with `nix run .#update-deps`
  # after changing any module's dependencies, then commit nix/deps.json.
  #
  # `pkg` is passed explicitly because this package is defined in a flake, not in
  # nixpkgs — the default `fetchDeps` behaviour is to look the package up by name
  # under `pkgs`, which would fail. `data` is a relative string (not a path
  # literal) so the updater can resolve it against this file's source position
  # and write the regenerated lockfile back into the working tree.
  mitmCache = gradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    inherit (finalAttrs) pname;
    data = depsData;
  };

  # Required on Darwin: the offline build talks to the mitm-cache proxy on
  # localhost, which the sandbox blocks without this.
  __darwinAllowLocalNetworking = true;

  # Only the standalone shadow JAR is needed; this transitively builds every
  # module the MCP server embeds.
  gradleBuildTask = ":jfr-mcp:shadowJar";
  # During lockfile generation, run the same task so every dependency the real
  # build pulls (across all toolchains and the included plugin build) is recorded.
  gradleUpdateTask = ":jfr-mcp:shadowJar";

  # Determinism for dependency recording: parallel resolution races requests
  # through the recording proxy and can drop transitive POMs (e.g. conflict
  # "loser" versions), leaving the offline build unable to re-run conflict
  # resolution. Disable parallelism and all caching so every artifact Gradle's
  # resolver touches is fetched and recorded on a single, repeatable pass.
  enableParallelBuilding = false;
  enableParallelChecking = false;
  enableParallelUpdating = false;
  gradleFlags = [
    "--no-build-cache"
    "--no-configuration-cache"
    # Strip mavenLocal() so every artifact is resolved through the recording
    # proxy (and later the pinned lockfile) rather than the host's ~/.m2, which
    # is empty in the sandbox. Applies to both the record and offline phases.
    "--init-script"
    (toString ./no-maven-local.init.gradle)
  ];

  # Tests require large JFR recordings fetched from Dropbox at runtime; skip them
  # in the hermetic build. Correctness of the server is validated separately.
  doCheck = false;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/jfr-mcp $out/bin
    cp jfr-mcp/build/libs/jfr-mcp-*-all.jar $out/share/jfr-mcp/jfr-mcp.jar

    makeWrapper ${jdk25}/bin/java $out/bin/jfr-mcp \
      --add-flags "-jar $out/share/jfr-mcp/jfr-mcp.jar"

    runHook postInstall
  '';

  # Expose the lockfile updater so `nix run .#update-deps` works.
  passthru.updateScript = finalAttrs.finalPackage.mitmCache.updateScript;

  meta = {
    description = "MCP server for JFR analysis (Jafar) — lets AI agents analyze Java Flight Recordings";
    homepage = "https://github.com/btraceio/jafar/tree/main/jfr-mcp";
    license = lib.licenses.asl20;
    mainProgram = "jfr-mcp";
    platforms = lib.platforms.unix;
  };
})
