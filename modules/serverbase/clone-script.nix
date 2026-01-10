{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "clone";
  runtimeInputs = (
    with pkgs;
    [
      coreutils
      git
      openssh
    ]
  );
  text = ''
    set -euo pipefail
    chown_parent_dir() {
      if ! [ -v 1 ]; then
        echo "No directory provided."
        exit 1
      fi
      if ! [ -v 2 ]; then
        echo "No chown provided."
        exit 1
      fi
      if ! [ -v 3 ]; then
        echo "No dry-run provided."
        exit 1
      fi
      local dir="$1"
      local chown="$2"
      local dry_run="$3"
      local parent_dir
      parent_dir=$(dirname "$dir")
      if ! [ -z "$chown" ] && ! [ -d "$parent_dir" ]; then
        echo "Creating parent dir $parent_dir..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m mkdir -p $parent_dir\e[0m"
        else
          mkdir -p "$parent_dir"
        fi
        echo "Creation done."
        echo "Changing owner for $parent_dir to $chown..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m chown -R $chown $parent_dir\e[0m"
        else
          chown -R "$chown" "$parent_dir"
        fi
        echo "Done changing owner."
      fi
    }
    _clone() {
      local clone_url=""
      local destination_dir=""
      local symlink_dir=""
      local private_git_origin=""
      local git_askpass_file=""
      local chown=""
      local dry_run=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
        --dry-run)
          dry_run=true
          shift
          ;;
        --symlink|--symlink-dir|-s)
          if [ ! -v 2 ]; then
            echo -e "\e[31mNo value provided for symlink.\e[0m" >&2
            exit 1
          fi
          symlink_dir="$2"
          shift
          shift
          ;;
        --private-git-origin|-p)
          if [ ! -v 2 ]; then
            echo -e "\e[31mNo value provided for private git origin.\e[0m" >&2
            exit 1
          fi
          private_git_origin="$2"
          shift
          shift
          ;;
        --git-askpass-file)
          if [ ! -v 2 ]; then
            echo -e "\e[31mNo value provided for git askpass file.\e[0m" >&2
            exit 1
          fi
          git_askpass_file="$2"
          shift
          shift
          ;;
        --chown)
          if [ ! -v 2 ]; then
            echo -e "\e[31mNo value provided for chown.\e[0m" >&2
            exit 1
          fi
          chown="$2"
          shift
          shift
          ;;
        --*)
          echo -e "\e[31mOption $1 not recognized.\e[0m" >&2
          exit 1
          ;;
        *)
          if [ -z "$clone_url" ]; then
            clone_url="$1"
          elif [ -z "$destination_dir" ]; then
            destination_dir="$1"
          else
            echo -e "\e[31mPositional argument $1 not recognized.\e[0m" >&2
            exit 1
          fi
          shift
          ;;
        esac
      done
      if [ -z "$clone_url" ]; then
        echo -e "\e[31mThe clone url was not provided.\e[0m" >&2
        exit 1
      fi
      if [ -z "$destination_dir" ]; then
        echo -e "\e[31mThe destination directory was not provided.\e[0m" >&2
        exit 1
      fi
      if ! [ -z "$git_askpass_file" ] && [[ $clone_url == https://* ]]; then
        export GIT_ASKPASS="$git_askpass_file"
        export GIT_TERMINAL_PROMPT=0
      fi
      chown_parent_dir "$destination_dir" "$chown" "$dry_run"
      echo "Cloning..."
      if $dry_run; then
        echo -e "\e[32mWould run:\e[34m git clone --recurse-submodules $clone_url $destination_dir\e[0m"
      else
        git clone --recurse-submodules "$clone_url" "$destination_dir"
      fi
      echo "Cloning done."
      if ! [ -z "$symlink_dir" ]; then
        echo "Now removing $symlink_dir so it can be symlinked later..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m rm -rf $symlink_dir\e[0m"
        else
          rm -rf "$symlink_dir"
        fi
        chown_parent_dir "$symlink_dir" "$chown" "$dry_run"
        echo "Removal done, now symlinking $destination_dir to $symlink_dir..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m ln -s $destination_dir $symlink_dir\e[0m"
        else
          ln -s "$destination_dir" "$symlink_dir"
        fi
        if ! [ -z "$chown" ]; then
          echo "Changing owner for $symlink_dir to $chown..."
          if $dry_run; then
            echo -e "\e[32mWould run:\e[34m chown -R $chown $symlink_dir\e[0m"
          else
            chown -R "$chown" "$symlink_dir"
          fi
          echo "Done changing owner."
        fi
        echo "Symlinking done."
      fi
      if ! [ -z "$private_git_origin" ]; then
        cd "$destination_dir"
        echo "Switching origin to $private_git_origin..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m git remote set-url origin $private_git_origin\e[0m"
          echo -e "\e[32mWould run:\e[34m git submodule sync\e[0m"
        else
          git remote set-url origin "$private_git_origin"
          git submodule sync
        fi
        echo "Done switching origin."
      fi
      if ! [ -z "$chown" ]; then
        echo "Changing owner for $destination_dir to $chown..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m chown -R $chown $destination_dir\e[0m"
        else
          chown -R "$chown" "$destination_dir"
        fi
        echo "Done changing owner."
      fi
    }
    _clone "$@"
  '';
}
