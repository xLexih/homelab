{pkgs, ...}: {
  environment.enableAllTerminfo = true;
  environment.systemPackages = [pkgs.ncurses];

  programs.nix-index-database.comma.enable = true;

  programs.bash = {
    completion.enable = true;
    shellAliases = {
      ".." = "cd ..";
      "..." = "cd ../..";
      c = "clear";
      k = "kubectl";
      kg = "kubectl get";
      kgp = "kubectl get pods -A";
      kgn = "kubectl get nodes -o wide";
      ll = "ls -alFh --color=auto";
      la = "ls -A --color=auto";
      l = "ls -CF --color=auto";
      j = "journalctl";
      jc = "journalctl -u";
      tf = "tail -f";
    };

    interactiveShellInit = ''
      shopt -s histappend checkwinsize cmdhist globstar
      HISTCONTROL=ignoreboth:erasedups
      HISTSIZE=10000
      HISTFILESIZE=20000
      HISTTIMEFORMAT='%F %T  '
      export HISTCONTROL HISTSIZE HISTFILESIZE HISTTIMEFORMAT
      export LESS='-FRX'

      bind '"\e[A": history-search-backward'
      bind '"\e[B": history-search-forward'
    '';

    promptInit = ''
      if [[ -n "''${NO_COLOR:-}" || "$TERM" == dumb ]]; then
        _CL_RESET=""
        _CL_PURPLE=""
        _CL_LAVENDER=""
        _CL_BLUE=""
        _CL_MINT=""
        _CL_PINK=""
        _CL_DIM=""
      elif (( $(tput colors 2>/dev/null || printf 0) >= 256 )); then
        _CL_RESET='\[\e[0m\]'
        _CL_PURPLE='\[\e[38;5;141m\]'
        _CL_LAVENDER='\[\e[38;5;183m\]'
        _CL_BLUE='\[\e[38;5;110m\]'
        _CL_MINT='\[\e[38;5;151m\]'
        _CL_PINK='\[\e[38;5;218m\]'
        _CL_DIM='\[\e[38;5;103m\]'
      else
        _CL_RESET='\[\e[0m\]'
        _CL_PURPLE='\[\e[95m\]'
        _CL_LAVENDER='\[\e[95m\]'
        _CL_BLUE='\[\e[94m\]'
        _CL_MINT='\[\e[92m\]'
        _CL_PINK='\[\e[91m\]'
        _CL_DIM='\[\e[90m\]'
      fi

      __cluster_prompt() {
        local exit_code=$?
        local branch="" git_context="" marker title=""
        if (( exit_code == 0 )); then
          marker="$_CL_MINT∴"
        else
          marker="$_CL_PINK×$exit_code"
        fi
        if command -v git >/dev/null 2>&1; then
          branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null ||
            git rev-parse --short HEAD 2>/dev/null) || branch=""
          [[ -z "$branch" ]] ||
            git_context=" $_CL_DIMon $_CL_PINK$branch$_CL_RESET"
        fi
        case "$TERM" in
          xterm*|screen*|tmux*|kitty*|foot*|wezterm*)
            title='\[\e]0;\u@\h: \w\a\]'
            ;;
        esac
        PS1="$title$marker $_CL_LAVENDER\u$_CL_DIM@$_CL_PURPLE\h$_CL_DIM:$_CL_BLUE\w$git_context $_CL_PURPLEλ$_CL_RESET "
      }
      PROMPT_COMMAND=__cluster_prompt
    '';
  };
}
