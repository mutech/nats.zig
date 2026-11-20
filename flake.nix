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
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ zig natscli goLatest pkgs.git buildNatsServerFork ];

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
