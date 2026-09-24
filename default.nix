{ lib
, stdenv
, nodejs_22
, bubblewrap
, makeWrapper
, writeShellScript
, fetchurl
, cacert
, ripgrep
, patchelf
, callPackage
}:

let
  claudeCode = callPackage ./claude.nix { runtime = "native"; };

  # Create the sandboxed wrapper script
  sandboxWrapper = writeShellScript "claude-sandbox" ''
    #!${stdenv.shell}
    
    # Parse command line flags
    ENABLE_FUSE=0
    ENABLE_SSH_GIT=0
    ENABLE_LIBVIRT=0
    ENABLE_DOCKER=0
    ENABLE_GH=0
    DEBUG=0
    CLAUDE_ARGS=()

    # Allow enabling gh via environment variable (equivalent to --enable-gh).
    if [ "''${GH_ENABLE:-0}" = "1" ]; then
      ENABLE_GH=1
      ENABLE_SSH_GIT=1
    fi

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --fuse)
          ENABLE_FUSE=1
          shift
          ;;
        --ssh-git)
          ENABLE_SSH_GIT=1
          shift
          ;;
        --libvirt)
          ENABLE_LIBVIRT=1
          shift
          ;;
        --docker)
          ENABLE_DOCKER=1
          shift
          ;;
        --enable-gh)
          ENABLE_GH=1
          ENABLE_SSH_GIT=1
          shift
          ;;
        --debug)
          DEBUG=1
          shift
          ;;
        *)
          CLAUDE_ARGS+=("$1")
          shift
          ;;
      esac
    done
    
    # Create isolated sandbox home directory
    SANDBOX_HOME="/tmp/claude-sandbox-home-$$"
    SANDBOX_TMP="/tmp/claude-sandbox-tmp-$$"
    trap 'rm -rf "$SANDBOX_HOME" "$SANDBOX_TMP"' EXIT

    mkdir -p "$SANDBOX_TMP"
    mkdir -p "$SANDBOX_HOME"
    mkdir -p "$SANDBOX_HOME/.cache"
    mkdir -p "$SANDBOX_HOME/.config"
    # Make sure the working directory path exists in the sandbox  
    mkdir -p "$SANDBOX_HOME/$(echo "$PWD" | sed "s|^/home/$USER||")"
    USER=$(whoami)
    
    # Only allow access to current project directory and essential system files
    ALLOWLIST=(
      "$SANDBOX_HOME:/home/$USER"
      "$PWD"                # current project dir (read-write)
      "ro:/etc"             # System configuration (read-only)
      "/nix"
      "ro:/run/current-system/sw"
      "ro:/bin/sh"
      "ro:/usr/bin/env"     # env command
      "$SANDBOX_TMP:/tmp"
      "/home/$USER/.cloudflared"
    )
    HOME_ALLOW=(
      ".claude"
      ".claude.json"
      ".android"
      ".ansible"
      ".cargo"
      ".config/claude"
      ".config/claude-sandbox"
      ".config/nix"
      ".cursor"
      ".docker"
      ".go"
      ".gradle"
      ".java"
      ".nix-channels"
      ".nix-defexpr"
      ".nix-profile"
      ".npm"
      ".yarn"
    )
    CACHE_DIRS=(
      "go"
      "pip"
      "deno"
      "pnpm"
      "yarn"
      "uv"
      "huggingface"
      "cached-nix-shell"
      "nix"
      "nix-hug"
      "gradle"
      "zig"
      # Additional language-specific caches and tools
      "bun"
      "black"
      "gopls"
      "jedi"
      "lua-language-server"
      "pylint"
      "staticcheck"
      "typescript"
      "fish"
      "fontconfig"
      "prisma"
      "prisma-nodejs"
      "puppeteer"
      "tokenizer"
      "whisper"
    )
    for cache_dir in "''${CACHE_DIRS[@]}"; do
      if [ -d "$HOME/.cache/$cache_dir" ]; then
        ALLOWLIST+=( "$HOME/.cache/$cache_dir" )
      fi
    done
    for cache_dir in "''${HOME_ALLOW[@]}"; do
      if [ -e "$HOME/$cache_dir" ]; then
        ALLOWLIST+=( "$HOME/$cache_dir" )
      fi
    done

    # Add conditional paths based on flags
    if [ "$ENABLE_FUSE" -eq 1 ]; then
      # Allow access to /tmp for fuse mounts
      ALLOWLIST+=( "/tmp" )
      # Allow access to common fuse mount points
      if [ -d "/run/user/$(id -u)" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)" )
      fi
      # Allow access to /dev/fuse for FUSE operations
      ALLOWLIST+=( "/dev/fuse" )
    fi
    
    if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
      # Allow access to SSH and git config in real home
      if [ -d "$HOME/.ssh" ]; then
        ALLOWLIST+=( "$HOME/.ssh" )
      fi
      if [ -d "$HOME/.gitconfig" ] || [ -f "$HOME/.gitconfig" ]; then
        ALLOWLIST+=( "$HOME/.gitconfig" )
      fi
      if [ -d "$HOME/.git-credentials" ] || [ -f "$HOME/.git-credentials" ]; then
        ALLOWLIST+=( "$HOME/.git-credentials" )
      fi
      # Also need SSH agent socket if it exists
      if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
        ALLOWLIST+=( "$SSH_AUTH_SOCK" )
      fi
      # GnuPG for git commit signing
      if [ -d "$HOME/.gnupg" ]; then
        ALLOWLIST+=( "$HOME/.gnupg" )
      fi
      # GPG agent socket
      if [ -n "$GPG_AGENT_INFO" ]; then
        GPG_SOCK=$(echo "$GPG_AGENT_INFO" | cut -d: -f1)
        if [ -e "$GPG_SOCK" ]; then
          ALLOWLIST+=( "$GPG_SOCK" )
        fi
      fi
      # Modern gpg agent socket location
      if [ -S "/run/user/$(id -u)/gnupg/S.gpg-agent" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)/gnupg/S.gpg-agent" )
      fi
    fi
    
    if [ "$ENABLE_LIBVIRT" -eq 1 ]; then
      # Allow access to libvirt socket
      if [ -S "/var/run/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/var/run/libvirt/libvirt-sock" )
      fi
      if [ -S "/run/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/run/libvirt/libvirt-sock" )
      fi
      # Allow access to user session libvirt socket
      if [ -S "/run/user/$(id -u)/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)/libvirt/libvirt-sock" )
      fi
    fi

    if [ "$ENABLE_GH" -eq 1 ]; then
      [ "$DEBUG" -eq 1 ] && printf "[sandbox] --enable-gh: running 'gh auth token'...\n" >&2
      GH_TOKEN=$(gh auth token 2>/dev/null)
      if [ -n "$GH_TOKEN" ]; then
        [ "$DEBUG" -eq 1 ] && printf "[sandbox] --enable-gh: got token (%d chars), will set GH_TOKEN\n" "''${#GH_TOKEN}" >&2
      else
        printf "[sandbox] --enable-gh: WARNING - 'gh auth token' failed. Are you logged in?\n" >&2
      fi
    fi

    if [ "$ENABLE_DOCKER" -eq 1 ]; then
      # Allow access to Docker socket
      if [ -S "/var/run/docker.sock" ]; then
        ALLOWLIST+=( "/var/run/docker.sock" )
      fi
      # Some systems use /run instead of /var/run
      if [ -S "/run/docker.sock" ]; then
        ALLOWLIST+=( "/run/docker.sock" )
      fi
    fi
    
    # Always read config file if it exists
    CONFIG_FILE="$HOME/.config/claude-sandbox/config.json"
    if [ -f "$CONFIG_FILE" ]; then
      # Parse the JSON config file
      if command -v jq >/dev/null 2>&1; then
        # Use jq if available
        if [ -f "$CONFIG_FILE" ]; then
          # Read includeFolders array
          while IFS= read -r folder; do
            # Expand tilde to home directory
            expanded_folder=$(echo "$folder" | sed "s|^~|$HOME|")
            if [ -d "$expanded_folder" ]; then
              ALLOWLIST+=( "$expanded_folder" )
            fi
          done < <(jq -r '.includeFolders[]? // empty' "$CONFIG_FILE" 2>/dev/null)
          
          # Read includeHomePatterns array
          while IFS= read -r pattern; do
            # Add to HOME_ALLOW if it exists
            if [ -e "$HOME/$pattern" ]; then
              ALLOWLIST+=( "$HOME/$pattern" )
            fi
          done < <(jq -r '.includeHomePatterns[]? // empty' "$CONFIG_FILE" 2>/dev/null)
        fi
      else
        # Fallback to basic parsing if jq is not available
        echo "Warning: jq not found. Please install jq for proper config parsing." >&2
      fi
    fi

    whitelisted_envs=(
      "SHELL"
      "PATH"
      "HOME"
      "USER"
      "LOGNAME"
      "MAIL"
      "TERM"
      "SSL_CERT_FILE"
      "NIX_SSL_CERT_FILE"
      "CURL_CA_BUNDLE"
      "CLAUDE_CODE_OAUTH_TOKEN"
    )
    env_args=()
    for env in "''${whitelisted_envs[@]}"; do
      if [ -n "''${!env}" ]; then
        env_args+=( --setenv "$env" "''${!env}" )
      fi
    done
    env_args+=( --setenv "NODE_ENV" "production" )
    if [ "$ENABLE_GH" -eq 1 ] && [ -n "$GH_TOKEN" ]; then
      env_args+=( --setenv "GH_TOKEN" "$GH_TOKEN" )
      [ "$DEBUG" -eq 1 ] && printf "[sandbox] GH_TOKEN added to env_args\n" >&2
    fi
    env_args+=( --setenv "SHELL" "$(readlink $(which $SHELL))" )
    env_args+=( --setenv "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY" "1")
    env_args+=( --setenv "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1")
    env_args+=( --setenv "CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL" "1")
    env_args+=( --setenv "DISABLE_AUTOUPDATER" "1")
    env_args+=( --setenv "DISABLE_ERROR_REPORTING" "1")
    env_args+=( --setenv "DISABLE_BUG_COMMAND" "1")
    env_args+=( --setenv "DISABLE_TELEMETRY" "1")
    
    # Pass SSH_AUTH_SOCK and GPG variables if --ssh-git is enabled
    if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
      if [ -n "$SSH_AUTH_SOCK" ]; then
        env_args+=( --setenv "SSH_AUTH_SOCK" "$SSH_AUTH_SOCK" )
      fi
      if [ -n "$GPG_AGENT_INFO" ]; then
        env_args+=( --setenv "GPG_AGENT_INFO" "$GPG_AGENT_INFO" )
      fi
      if [ -n "$GPG_TTY" ]; then
        env_args+=( --setenv "GPG_TTY" "$GPG_TTY" )
      fi
    fi

    if [ "$DEBUG" -eq 1 ]; then
      printf "[sandbox] ALLOWLIST (%d entries):\n" "''${#ALLOWLIST[@]}" >&2
      for item in "''${ALLOWLIST[@]}"; do
        printf "[sandbox]   %s\n" "$item" >&2
      done
      printf "[sandbox] env_args (%d entries):\n" "''${#env_args[@]}" >&2
      for item in "''${env_args[@]}"; do
        case "$item" in
          --setenv) printf "[sandbox]   --setenv " >&2 ;;
          GH_TOKEN) printf "GH_TOKEN=<redacted>\n" >&2 ;;
          *) printf "%s " "$item" >&2 ;;
        esac
      done
      printf "\n" >&2
    fi

    # Build bwrap argument list
    args=(
      --unshare-all                         # isolate every namespace except network
      --unshare-user                        # isolate user namespace
      --unshare-pid                         # isolate pid namespace
      --unshare-uts                         # isolate uts namespace
      --unshare-ipc                         # isolate ipc namespace
      --share-net                           # keep Internet access for API calls
      --die-with-parent                     # auto-kill if parent shell exits
      --proc /proc --dev /dev               # minimal /proc and /dev
      --ro-bind /nix /nix                   # Nix store read-only
    )

    # Create /usr/bin directory and bind node
    args+=(
      --tmpfs /usr
      --dir /usr/bin
      "''${env_args[@]}"
    )

    for p in "''${ALLOWLIST[@]}"; do
      if [[ "$p" == ro:* ]]; then
        p="''${p#ro:}"; 
        if [ -e "$p" ]; then
          args+=( --ro-bind "$p" "$p" )
        fi
      elif [[ "$p" == *:* ]]; then
        source="''${p%%:*}"
        dest="''${p#*:}"
        if [ -e "$source" ]; then
          args+=( --bind "$source" "$dest" )
        fi
      else
        if [ -e "$p" ]; then
          args+=( --bind "$p" "$p" )
        fi
      fi
    done

    # Use the claude executable from the npm package
    if [ $DRY_RUN ]; then
      echo ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$out/bin/claude-bin" "''${CLAUDE_ARGS[@]}"
    elif [ $START_SHELL ]; then
      exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- $(readlink $(which $SHELL))
    else
      exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$out/bin/claude-bin" "''${CLAUDE_ARGS[@]}"
    fi
  '';

in stdenv.mkDerivation rec {
  pname = "claude-sandbox";
  version = "2.1.114";

  nativeBuildInputs = [ makeWrapper ripgrep patchelf ];
  buildInputs = [ nodejs_22 bubblewrap cacert ];

  src = builtins.filterSource (path: type: false) ./.;

  # No build phase needed
  dontBuild = true;

  installPhase = ''
    # Create directories
    mkdir -p $out/bin

    # Copy package contents
    cp -r ${claudeCode}/bin/claude $out/bin/claude-bin

    # Create our sandboxed wrapper
    cp ${sandboxWrapper} $out/bin/claude-sandbox
    chmod +x $out/bin/claude-sandbox

    # Alias the sandboxed claude to the original claude
    ln -s $out/bin/claude-sandbox $out/bin/claude

    # Substitute the $out placeholder with actual output path
    substituteInPlace $out/bin/claude-sandbox \
      --replace '$out/bin/claude-bin' "$out/bin/claude-bin"
  '';

  meta = with lib; {
    description = "Sandboxed Claude Code environment using bubblewrap";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "claude-sandbox";
  };
}
