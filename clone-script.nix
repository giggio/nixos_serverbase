{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "clone";
  runtimeInputs = (with pkgs; [ coreutils git ]);
  text = ''
    set -euo pipefail
    _clone() {
      local clone_url=""
      local destination_dir=""
      local symlink_dir=""
      local private_git_origin=""
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
        echo "Removal done, now symlinking $destination_dir to $symlink_dir..."
        if $dry_run; then
          echo -e "\e[32mWould run:\e[34m ln -s $destination_dir $symlink_dir\e[0m"
        else
          ln -s "$destination_dir" "$symlink_dir"
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
    }
    _clone "$@"
  '';
}
