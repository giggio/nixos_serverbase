set -eu

# ensure basic tools available on PATH (these come from boot.initrd.packages)
PATH="$PATH:/bin:/usr/bin:/sbin:/usr/sbin"
export PATH

# terminal type (helps readline)
TERM=${TERM:-linux}
export TERM

# Find and export TERMINFO so bash/readline can find the linux terminal definition
# This scans the PATH (which includes nix store paths) for a valid share/terminfo directory
if [ -z "${TERMINFO:-}" ]; then
  for p in $(echo "$PATH" | tr ':' ' '); do
    if [ -d "$p/../share/terminfo" ]; then
      export TERMINFO="$p/../share/terminfo"
      break
    fi
  done
fi

# make sure pseudo-ttys and proc/sys exist
if ! mountpoint -q /dev/pts 2>/dev/null; then
  mkdir -p /dev/pts
  mount -t devpts devpts /dev/pts || true
fi
for d in proc sys; do
  if ! mountpoint -q /$d 2>/dev/null; then
    mkdir -p /$d
    mount -t $d $d /$d || true
  fi
done

# small, ephemeral home so bash can write history and read inputrc / bashrc
HOME=/run/initrd-shell/home
mkdir -p "$HOME"
export HOME

# minimal readline / inputrc so arrow keys and basic editing work
if ! [ -f "$HOME/.inputrc" ]; then
cat > "$HOME/.inputrc" <<'INPUTRC'
set editing-mode emacs
set enable-keypad on
"\e[A": previous-history
"\e[B": next-history
"\e[C": forward-char
"\e[D": backward-char
INPUTRC
fi

# minimal interactive bash config
if ! [ -f "$HOME/.bashrc" ]; then
cat > "$HOME/.bashrc" <<'BASHRC'
# prompt, history and helpful aliases
export PS1='[initrd \u@\h \W]\$ '
HISTFILE="$HOME/.bash_history"
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend
alias ll='ls -alF --color=auto 2>/dev/null || ls -alF'
alias l='ls -CF'
# source system-wide profile if present (non-fatal)
[ -f /etc/profile ] && . /etc/profile || true
BASHRC
fi

# if $BASH isn't set, fallback to /bin/bash or /bin/sh
BASH=${BASH:-/bin/bash}
if [ ! -x "$BASH" ]; then
  if [ -x /bin/bash ]; then
    BASH=/bin/bash
  else
    BASH=/bin/sh
  fi
fi

# export HISTFILE again for bash when it starts
export HISTFILE="$HOME/.bash_history"

if [ ! -s /etc/passwd ]; then
  printf 'root:x:0:0:root:/root:/bin/sh\n' > /etc/passwd
fi
if [ ! -s /etc/group ]; then
  printf 'root:x:0:\n' > /etc/group
fi
export USER=root LOGNAME=root

set +e
if ! TTY="$(tty 2>/dev/null)"; then
  TTY="/dev/console"
fi
# Enable job control (monitor mode) so CTRL+C works for child processes
set -m
# Reset signals that might have been ignored by the init system
trap - INT QUIT TSTP

if ! exec setsid -c "$BASH" -i <"$TTY" >"$TTY" 2>&1; then
  echo "Failed to use 'setsid', falling back to calling bash directly"
  # handoff to an interactive bash; -i forces interactive so readline is enabled
  exec "$BASH" -i
fi
