{ config, lib, pkgs, ... }:
{
  home.stateVersion = "25.11";
  home.username = "mauri";
  home.homeDirectory = "/home/mauri";

  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    eza
    jq
    yq
    file
    tree
    unzip
    dig
    just
    # Orca agent box — runtime + CLIs de agentes
    nodejs_22
    gh
    claude-code
    # Toolchain para que el relay SSH de Orca compile node-pty/@parcel/watcher
    gcc
    gnumake
    python3
    binutils
    # Toolchain per-proyecto (versiones por repo, aisladas): uv = Python; direnv
    # auto-activa el entorno al cd en cada worktree; corepack (viene con node) = pnpm.
    uv
  ];

  programs.git = {
    enable = true;
    userName = "Mauricio Antolin";
    userEmail = "otros@mauricioantolin.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      # gh como credential helper (equivalente a `gh auth setup-git`, que no puede
      # correr porque home-manager hace ~/.config/git/config read-only).
      credential."https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
      credential."https://gist.github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "eza -la --git";
      cat = "bat --paging=never";
      gs = "git status";
    };
  };

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    terminal = "screen-256color";
  };

  # direnv: auto-activa el entorno por repo (`use flake` / layout uv) al entrar al worktree.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.htop.enable = true;
}
