{
  autoPatchelfHook,
  fetchurl,
  gcc-unwrapped,
  lib,
  libcap,
  ncurses,
  openssl,
  stdenv,
  zlib,
}: let
  latestHash = "sha256-PsVQUxCWCNUDj35QdQ99Jfdo39dA/vBxqnEOJVm2Oqw=";
in
  stdenv.mkDerivation rec {
    pname = "codex";
    version = "0.164.0";

    src = fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
      sha256 = latestHash;
    };

    nativeBuildInputs = [autoPatchelfHook libcap openssl gcc-unwrapped.lib zlib];
    # ncurses provides libtinfo for the bundled zsh
    buildInputs = [ncurses];

    # No build phase needed
    sourceRoot = ".";

    installPhase = ''
          runHook preInstall

          # Create directories
          mkdir -p $out/bin $out/libexec/codex

          # Install the full codex package, preserving its layout. codex resolves
          # helpers (bin/codex-code-mode-host, codex-resources/, codex-path/)
          # relative to its own executable, so they must stay together.
          cp -r bin codex-resources codex-path codex-package.json $out/libexec/codex/
          chmod -R u+w $out/libexec/codex

          ln -s $out/libexec/codex/bin/codex $out/bin/codex

          runHook postInstall
    '';

    meta = with lib; {
      description = "Codex, the coding agent of OpenAI";
      homepage = "https://github.com/openai/codex";
      license = licenses.mit;
      maintainers = [];
      platforms = platforms.linux;
      mainProgram = "codex";
    };
  }
