{
  description = "Monad todo app: SSR backend + typed-event wasm SPA, packaged as an OCI image";

  # The Monad CI publishes the compiler ladder to a Cachix cache. Use it (with
  # `nix build --accept-flake-config ...`) so this flake does not rebuild the
  # self-hosted compiler from source.
  nixConfig = {
    extra-substituters = [
      "https://monad-lang.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "monad-lang.cachix.org-1:iydtAH4RfGNfAimoaX7vfcACG/X8R5A3Iw9wL8dkFDU="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  inputs = {
    # The toolchain, the runtime sources and the git-dependency sources all
    # come from the Monad flake, pinned to the same revision as every
    # mote.toml.
    monad.url = "github:monad-lang/monad/6a59e0909cbc35ba1607061f7926d4347baf6f31";

    # Follow the Monad flake's nixpkgs for the image build as well: the
    # compiler's cached derivation was built with that pin, and one nixpkgs
    # means one llvm/clang/glibc closure throughout. (devenv still uses its
    # own pin for the developer shell.)
    nixpkgs.follows = "monad/nixpkgs";
  };

  outputs = { self, nixpkgs, monad }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      monadPkg = monad.packages.${system}.monad;

      # Reuse the dev shell's pinned wasi-sdk (34.0) instead of duplicating
      # the derivation. It is selected by absolute $WASI_SDK_PATH, so its
      # clang stays off PATH.
      wasiSdk = import ./nix/wasi-sdk.nix { inherit pkgs; };

      monadRev = "6a59e0909cbc35ba1607061f7926d4347baf6f31";
      monadUrl = "https://github.com/monad-lang/monad.git";
      # sha256 of the URL string above; the git cache layout is
      # $MONAD_HOME/cache/git/checkouts/<this>/<rev>. Verified against a
      # real `monad fetch` cache.
      monadUrlKey = "db09daedec509dc62561501b1050f28d47ccdc980278e2d6be86b2b8058f79a8";

      # Hermetic stand-in for `monad fetch`'s checkout cache:
      # build/check/test only read cache/git/checkouts/<url-key>/<rev>, while
      # the bare mirror under cache/git/db is used only by fetch itself. The
      # tree comes from the monad flake input (same git revision the locks
      # pin), and the app builds with --locked and never networks.
      monadHome = pkgs.runCommand "monad-home" { } ''
        mkdir -p $out/cache/git/checkouts/${monadUrlKey}
        cp -a ${monad.outPath} $out/cache/git/checkouts/${monadUrlKey}/${monadRev}
      '';

      app = pkgs.stdenv.mkDerivation {
        pname = "todo-app";
        version = "0.1.0";
        src = self;

        # The Monad compiler writes target/ and regenerates the tracked
        # loader files under web/; build from a writable copy.
        dontUnpack = true;
        dontPatchELF = true;
        dontStrip = true;

        nativeBuildInputs = with pkgs; [
          llvm # llc (also supplied by the monad wrapper)
          lld # wasm-ld
          clang
          pkg-config
          sqlite # [link] pkg-config = ["sqlite3"]
          coreutils
          findutils
          bash
          patchelf
        ];

        buildPhase = ''
          runHook preBuild

          cp -r $src app
          chmod -R u+w app

          # Git dependencies resolve from a writable MONAD_HOME; the
          # compiler's ambient toolchain sources (init/std/llvm/runtime) come
          # from the monad flake's source tree.
          cp -a ${monadHome} $TMPDIR/monad-home
          chmod -R u+w $TMPDIR/monad-home

          export MONAD_HOME=$TMPDIR/monad-home
          export MONAD_ROOT=${monad.outPath}
          export WASI_SDK_PATH=${wasiSdk}
          export HOME=$TMPDIR/home
          mkdir -p $HOME

          cd app
          ${monadPkg}/bin/monad check --workspace --locked

          ${monadPkg}/bin/monad build --locked \
            --target wasm32-unknown-unknown todo-spa -o "$PWD/web/app.wasm"
          ${monadPkg}/bin/monad build --locked todo-webgen
          ./target/debug/todo-webgen
          ${monadPkg}/bin/monad build --locked --release todo-backend

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          cd "$TMPDIR/app"

          mkdir -p $out/app/bin $out/app/web $out/app/lib
          install -m755 target/release/todo-backend $out/app/bin/todo-backend

          # libsqlite3 is the one dynamic dependency outside glibc. Keep it
          # beside the binary and resolve it through $ORIGIN, so the image
          # closure stays app + glibc + sqlite and the compiler's
          # llvm/clang/gc RUNPATH is not inherited.
          # `pkgs.sqlite` defaults to the `bin` output in this nixpkgs; the
          # shared library lives in the `out` output.
          cp -a ${pkgs.sqlite.out}/lib/libsqlite3.so* $out/app/lib/
          patchelf \
            --set-interpreter ${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2 \
            --set-rpath '$ORIGIN/../lib:${pkgs.stdenv.cc.libc}/lib' \
            $out/app/bin/todo-backend

          install -m644 \
            web/boot.version web/boot.js web/web.gen.js web/web_runtime.gen.js \
            web/float_format.js web/app.wasm web/index.html \
            $out/app/web/

          install -m755 deploy/entrypoint.sh $out/app/entrypoint.sh

          # State is SQLite. The entrypoint passes --db /state/todos.db so
          # the database and its WAL/SHM files live on the mounted /state
          # volume; no symlink is installed under the read-only image root.

          runHook postInstall
        '';
      };

      image = pkgs.dockerTools.buildLayeredImage {
        name = "todo-app";
        tag = "latest";

        # This nixpkgs' dockerTools takes a list of roots (`contents`), not
        # the newer `copyToRoot` argument.
        contents = [
          (pkgs.buildEnv {
            name = "todo-app-image-root";
            paths = [ app pkgs.bash pkgs.coreutils ];
            pathsToLink = [ "/app" "/bin" ];
          })
        ];

        extraCommands = ''
          # `state` is normally a mounted PVC (fsGroup handles ownership).
          # The world-writable fallback keeps a plain `docker run` without a
          # volume working for the non-root user; fakeroot in the image layer
          # cannot chown to an unmapped uid.
          mkdir -p state tmp
          chmod 0777 state
          chmod 1777 tmp
        '';

        config = {
          User = "10001:10001";
          WorkingDir = "/app";
          Entrypoint = [ "/app/entrypoint.sh" ];
          Env = [ "PATH=/bin" "HOME=/tmp" ];
          ExposedPorts = { "8095/tcp" = { }; };
        };
      };
    in
    {
      packages.${system} = {
        default = app;
        image = image;
        monad-home = monadHome;
      };
    };
}
