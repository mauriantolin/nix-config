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
  ];

  programs.git = {
    enable = true;
    userName = "Mauricio Antolin";
    userEmail = "mmv@akapol.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
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

  programs.htop.enable = true;
}
