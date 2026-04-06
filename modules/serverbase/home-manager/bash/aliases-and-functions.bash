function my/ble-hook/rename-zellij-tab-before {
  if ! [ -v ZELLIJ ]; then
    return
  fi
  local args
  IFS=" " read -ra args <<<"$*"
  local prog_name="${args[0]}"
  set -- "${args[@]}"
  local tab_name="$prog_name"
  shift
  case "$prog_name" in
  less)
    tab_name="<"
    ;;
  nix-* | hm | sm | nr | nix)
    tab_name="󱄅"
    ;;
  bat)
    tab_name="󰭟"
    ;;
  vi | vim | nvim)
    local dir=
    dir="${PWD##*/}"
    tab_name=" $dir"
    ;;
  make)
    tab_name=" $1"
    ;;
  ssh)
    while [ "$#" -gt 0 ]; do
      case "$1" in
      -*) ;;
      *@*)
        tab_name="⚡ ${1#*@}"
        break
        ;;
      *)
        tab_name="⚡ $1"
        break
        ;;
      esac
      shift
    done
    ;;
  exit)
    return
    ;;
  *) ;;
  esac
  zellij action rename-tab "$tab_name"
}

function my/ble-hook/rename-zellij-tab-after {
  if [ -v ZELLIJ ]; then
    local dir=''
    if [ "$PWD" == "/tmp" ]; then
      dir="🗑️"
    elif [ "$PWD" == "$HOME" ]; then
      dir=🏡
    elif [[ "$PWD" == "$HOME"* ]]; then
      dir="${PWD#"$HOME"}"
      if [ ${#dir} -gt 10 ]; then
        dir="/../${dir##*/}"
      fi
      dir="🏡$dir"
    else
      if [ ${#PWD} -gt 10 ]; then
        dir="/../${PWD##*/}"
      else
        dir="$PWD"
      fi
    fi
    zellij action rename-tab "$dir" --tab-id "$(zellij action list-panes --json | jq -r "map(select(.id == $ZELLIJ_PANE_ID and .is_plugin == false))[0].tab_id")"
  fi
}

function zellij_cheats() {
  echo "Ctrl Alt Shift t => Tab
Ctrl Shift f => Search
Ctrl Shift g => Lock
Ctrl Shift m => Move
Ctrl Shift n => Resize
Ctrl Shift o => Session
Ctrl Shift p => Pane
Ctrl Shift q => Quit"
}

