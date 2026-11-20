{
  # Fork-local dev shell (mutech/nats.zig). Not part of upstream nats-io/nats.zig.
  #
  # Tool versions are read from .github/workflows/ci.yml (ZIG_VERSION,
  # NATS_CLI_VERSION), so the shell runs exactly what CI runs. A version bump
  # there fails evaluation here until its hash is added to `hashes` below.
  # Zig and the nats CLI come from their official (static) release archives,
  # the same ones mlugg/setup-zig and the CI install step download.
  description = "nats.zig (snats fork) dev shell, tool versions pinned to CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      # First capture of `re` over the lines of `file`; evaluation error if absent.
      grab = file: re:
        let
          hits = lib.filter (m: m != null)
            (map (builtins.match re) (lib.splitString "\n" (builtins.readFile file)));
        in if hits == [ ] then throw "flake.nix: no match for ${re} in ${toString file}"
           else builtins.head (builtins.head hits);

      ci = ./.github/workflows/ci.yml;
      versions = {
        zig = grab ci ''[[:space:]]*ZIG_VERSION: ([^[:space:]]+)[[:space:]]*'';
        natscli = lib.removePrefix "v" (grab ci ''[[:space:]]*NATS_CLI_VERSION: ([^[:space:]]+)[[:space:]]*'');
      };

      # x86_64-linux release archives, keyed by tool and version.
      hashes = {
        zig."0.16.0" = "sha256-cOSWZKdDdLSLUebz/fv0N/Y5XUJQkFBYi9SavlK6PQA=";
        zig."0.17.0" = "sha256-HL6d+fJ+a3jRTMvKQ7ZwOkBO957xxGPekB1/CI1OICY=";
        natscli."0.3.1" = "sha256-9IN0vm/JA7lUuQtykyF3K91bx0UjTt89Mc0Xq3noVik=";
      };

      fetchPinned = name: url: pkgs.fetchurl {
        inherit url;
        hash = hashes.${name}.${versions.${name}} or (throw ''
          flake.nix: CI pins ${name} ${versions.${name}}; add its hash to `hashes`:
            nix hash convert --hash-algo sha256 --to sri $(nix-prefetch-url ${url})'');
      };

      zig = pkgs.stdenvNoCC.mkDerivation {
        pname = "zig";
        version = versions.zig;
        src = fetchPinned "zig"
          "https://ziglang.org/download/${versions.zig}/zig-x86_64-linux-${versions.zig}.tar.xz";
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        # zig locates its lib/ relative to the resolved executable path.
        installPhase = ''
          mkdir -p $out/lib $out/bin
          cp -r . $out/lib/zig
          ln -s $out/lib/zig/zig $out/bin/zig
        '';
      };

      natscli = pkgs.stdenvNoCC.mkDerivation {
        pname = "natscli";
        version = versions.natscli;
        src = fetchPinned "natscli"
          "https://github.com/nats-io/natscli/releases/download/v${versions.natscli}/nats-${versions.natscli}-linux-amd64.zip";
        nativeBuildInputs = [ pkgs.unzip ];
        sourceRoot = ".";
        installPhase = ''install -Dm755 -t $out/bin "$(find . -type f -name nats -print -quit)"'';
      };

      # CI builds the UDS server fork from source at the commit pinned in
      # .github/workflows/ci.yml (NATS_SERVER_FORK_REPO/REF), with Go `stable`.
      # build-nats-server-fork reads that pin and builds exactly it, so local runs
      # test against the same server as CI. Building a local checkout instead (the
      # integration step of an upstream sync, before the pin is bumped) must be
      # explicit: `build-nats-server-fork DIR` or NATS_SERVER_FORK_DIR=DIR.
      # The built ref is recorded next to the binary; the shellHook warns when it
      # no longer matches the pin.
      goLatest =
        let names = lib.filter (n: builtins.match "go_1_[0-9]+" n != null) (builtins.attrNames pkgs);
            minor = n: lib.toInt (lib.removePrefix "go_1_" n);
        in pkgs.${lib.last (lib.sort (a: b: minor a < minor b)
             (lib.filter (n: (builtins.tryEval pkgs.${n}).success) names))};

      buildNatsServerFork = pkgs.writeShellApplication {
        name = "build-nats-server-fork";
        runtimeInputs = [ goLatest pkgs.git pkgs.gnugrep pkgs.gnused ];
        text = ''
          root="$(git rev-parse --show-toplevel)"
          ci="$root/.github/workflows/ci.yml"
          ci_var() { sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)$/\1/p" "$ci" | head -n1; }
          repo="$(ci_var NATS_SERVER_FORK_REPO)"; ref="$(ci_var NATS_SERVER_FORK_REF)"
          out="$root/.devshell/bin"; mkdir -p "$out"
          src="''${1:-''${NATS_SERVER_FORK_DIR:-}}"
          if [ -n "$src" ]; then
            built="local:$(cd "$src" && pwd)@$(git -C "$src" rev-parse HEAD)$(git -C "$src" diff --quiet || echo +dirty)"
          else
            src="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell/nats-server-src"
            [ -d "$src/.git" ] || git clone -q --filter=blob:none "$repo" "$src"
            git -C "$src" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$src" fetch -q origin
            git -C "$src" checkout -q --detach "$ref"
            built="$ref"
          fi
          echo "building nats-server: $built"
          go -C "$src" build -o "$out/nats-server" .
          echo "$built" > "$out/nats-server.ref"
          "$out/nats-server" --version
        '';
      };

      rerereTrain = pkgs.writeShellScriptBin "rerere-train" ''
        exec ${pkgs.bash}/bin/bash ${pkgs.git}/share/git/contrib/rerere-train.sh "$@"
      '';

      # QA runner mirroring ci.yml. Every target's full output goes to its own
      # log, wall time and exit code to summary.tsv and to the cross-session
      # timings file. No timeouts. All targets run even if one fails.
      #   qa fast   server pin, fmt-check, build, unit tests, UDS integration
      #   qa full   + every integration suite x every CI matrix mode
      #             (Debug, ReleaseFast, zio, ReleaseFast+zio)
      qa = pkgs.writeShellApplication {
        name = "qa";
        excludeShellChecks = [ "SC2329" ]; # targets are dispatched via "t_$name"
        runtimeInputs = [ pkgs.coreutils pkgs.gnused pkgs.git ];
        text = ''
          root="$(git rev-parse --show-toplevel)"
          cd "$root"
          export PATH="$root/.devshell/bin:$PATH"
          pin="$(sed -n 's/^[[:space:]]*NATS_SERVER_FORK_REF:[[:space:]]*//p' .github/workflows/ci.yml | head -n1)"

          t_server() {
            [ "$(cat .devshell/bin/nats-server.ref 2>/dev/null)" = "$pin" ] || build-nats-server-fork
            nats-server --version; cat .devshell/bin/nats-server.ref
          }
          t_fmt_check() { zig build fmt-check; }
          t_build()     { zig build; }
          t_unit()      { zig build test; }

          # Matrix modes as in ci.yml's integration job.
          mode_args() {
            case "$1" in
              debug) ;;
              releasefast) echo "-Doptimize=ReleaseFast" ;;
              zio) echo "-Dio_backend=zio" ;;
              releasefast_zio) echo "-Doptimize=ReleaseFast -Dio_backend=zio" ;;
            esac
          }
          suite() { local step="$1" mode="$2" args; args="$(mode_args "$mode")"
                    # shellcheck disable=SC2086
                    zig build "$step" $args; }
          modes="debug releasefast zio releasefast_zio"
          for m in $modes; do
            eval "t_uds_$m()   { suite test-integration-uds $m; }"
            eval "t_core_$m()  { suite test-integration $m; }"
            eval "t_micro_$m() { suite test-integration-micro $m; }"
            eval "t_tls_$m()   { suite test-integration-tls $m; }"
          done

          fast_targets="server fmt_check build unit uds_debug"
          full_targets="server fmt_check build unit"
          for m in $modes; do full_targets="$full_targets uds_$m core_$m micro_$m tls_$m"; done

          stage="''${1:-}"; shift || true
          case "$stage" in
            fast) targets="''${*:-$fast_targets}" ;;
            full) targets="''${*:-$full_targets}" ;;
            list) echo "fast: $fast_targets"; echo "full: $full_targets"; exit 0 ;;
            *) echo "usage: qa fast|full|list [TARGET...]" >&2; exit 2 ;;
          esac

          rev="$(git rev-parse --short HEAD)$(git diff --quiet || echo +dirty)"
          dir="$root/.devshell/qa/$(date -u +%Y%m%dT%H%M%SZ)-$stage"
          timings="''${XDG_STATE_HOME:-$HOME/.local/state}/snats-upstream-sync/timings.tsv"
          mkdir -p "$dir" "$(dirname "$timings")"
          [ -s "$timings" ] || printf 'date\trepo\trev\tstage\ttarget\tseconds\trc\thost\n' > "$timings"
          echo "qa $stage @ $rev (server pin ''${pin:0:9}) -> $dir"
          failed=0
          for t in $targets; do
            start=$(date +%s); set +e
            ( set -x; "t_$t" ) > "$dir/$t.log" 2>&1; rc=$?
            set -e; secs=$(( $(date +%s) - start ))
            printf '%s\t%s\t%s\n' "$t" "$secs" "$rc" >> "$dir/summary.tsv"
            printf '%s\tnats.zig\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$rev" "$stage" "$t" "$secs" "$rc" "$(hostname)" >> "$timings"
            printf '  %-24s rc=%-3s %6ss\n' "$t" "$rc" "$secs"
            [ "$rc" -eq 0 ] || failed=1
          done
          echo "logs: $dir"
          exit "$failed"
        '';
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ zig natscli goLatest pkgs.git buildNatsServerFork pkgs.mergiraf rerereTrain qa ];

        shellHook = ''
          root="$(git rev-parse --show-toplevel)"
          export PATH="$root/.devshell/bin:$PATH"
          # Go state for the fork server build: out of the tree and out of ~/go;
          # shared by the fork dev shells.
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell"
          export GOPATH="$cache/go"
          export GOMODCACHE="$cache/go/pkg/mod"
          export GOCACHE="$cache/go-build"
          echo "nats.zig dev shell: zig ${versions.zig}, nats CLI ${versions.natscli}"
          zon="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon 2>/dev/null)"
          [ -z "$zon" ] || [ "$zon" = "${versions.zig}" ] \
            || echo "  WARNING: build.zig.zon minimum_zig_version $zon != CI ZIG_VERSION ${versions.zig}"
          # A stock nats-server elsewhere on PATH lacks UDS; require the fork build,
          # at the commit CI pins.
          pin="$(sed -n 's/^[[:space:]]*NATS_SERVER_FORK_REF:[[:space:]]*//p' .github/workflows/ci.yml | head -n1)"
          if [ ! -x "$root/.devshell/bin/nats-server" ]; then
            echo "  no fork nats-server in .devshell/bin: run build-nats-server-fork"
          elif [ "$(cat "$root/.devshell/bin/nats-server.ref" 2>/dev/null)" != "$pin" ]; then
            echo "  NOTE: .devshell/bin/nats-server is $(cat "$root/.devshell/bin/nats-server.ref" 2>/dev/null || echo unknown), CI pins $pin"
          fi
        '';
      };
    };
}
