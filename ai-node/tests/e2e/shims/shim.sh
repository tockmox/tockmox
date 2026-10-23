#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# One script that stands in for every macOS command the roles call, selected by the name it was
# invoked under. It keeps just enough state under /var/lib/tockmox-sim to make the roles'
# read-then-write logic behave as it does on a Mac. It is a test double, not an emulator:
# the point is that the playbook's own logic (Jinja, ordering, idempotence) runs end to end.
S=/var/lib/tockmox-sim
mkdir -p "$S"/{loaded,submitted,users,defaults,brew,pf,pmset,calls}
me="$(basename "$0")"
echo "$me $*" >> "$S/calls.log"

case "$me" in
launchctl)
  sub="${1:-}"; shift
  case "$sub" in
    print) l="${1#system/}"; [ -e "$S/loaded/$l" ] && { echo "$l = {"; echo "}"; exit 0; }; exit 113 ;;
    bootstrap) shift; plist="$1"
               l="$(python3 - "$plist" <<'PY'
import plistlib, sys
print(plistlib.load(open(sys.argv[1], "rb"))["Label"])
PY
)"
               [ -e "$S/loaded/$l" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
               cp "$plist" "$S/loaded/$l"
               # A job gets a listener on its port, so the playbook's wait for the daemon is real and the
               # tests can see whether anything listens. A job that starts through start-when-firewalled
               # runs the real wrapper with a listener where the engine would be: the wrapper's waiting
               # is what is under test, not the engine.
               spec="$(python3 - "$plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
a = d["ProgramArguments"]
env = d.get("EnvironmentVariables") or {}
gated = a[0].endswith("/start-when-firewalled")
hp = env.get("OLLAMA_HOST", "")
if not hp:
    host, port = "127.0.0.1", ""
    for i, x in enumerate(a):
        if x == "--host" and i + 1 < len(a):
            host = a[i + 1]
        elif x == "--port" and i + 1 < len(a):
            port = a[i + 1]
        elif x == "-p" and i + 1 < len(a):
            host, port = "0.0.0.0", a[i + 1]
        elif x.startswith("--web.listen-address="):
            host, port = x.split("=", 1)[1].rsplit(":", 1)
    hp = host + ":" + port if port else ""
print("%s %s %s" % ("1" if gated else "0", hp or "-", a[0]))
PY
)"
               read -r gated hostport wrapper <<EOF
$spec
EOF
               [ "$hostport" = "-" ] && hostport=""
               if [ -n "$hostport" ]; then
                 LISTENER='import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
h,p=sys.argv[1].rsplit(":",1); s.bind((h,int(p))); s.listen(5)
while True:
    c,_=s.accept(); c.close()'
                 if [ "$gated" = 1 ]; then
                   setsid nohup timeout 1500 "$wrapper" python3 -c "$LISTENER" "$hostport" >"$S/listener.err" 2>&1 < /dev/null &
                 else
                   setsid nohup timeout 1500 python3 -c "$LISTENER" "$hostport" >"$S/listener.err" 2>&1 < /dev/null &
                 fi
                 echo $! > "$S/loaded/$l.pid"
                 case "$hostport" in *:11434)
                   i=0; while [ "$i" -lt 50 ]; do python3 -c 'import socket,sys
h,p=sys.argv[1].rsplit(":",1)
h="127.0.0.1" if h=="0.0.0.0" else h
socket.create_connection((h,int(p)),1).close()' "$hostport" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done ;;
                 esac
               fi
               exit 0 ;;
    bootout) l="${1#system/}"; [ -e "$S/loaded/$l" ] || exit 113
             [ -e "$S/loaded/$l.pid" ] && { kill "$(cat "$S/loaded/$l.pid")" 2>/dev/null; rm -f "$S/loaded/$l.pid"; }
             rm -f "$S/loaded/$l"; exit 0 ;;
    list) [ -n "${1:-}" ] || exit 0; [ -e "$S/submitted/$1" ] || [ -e "$S/loaded/$1" ] && exit 0; exit 113 ;;
    # macOS 27.0.1, measured 2026-10-22: submit returns 0 and starts nothing that list or print can
    # see. The stand-in does the same, so a role that goes back to submit fails here as it did there.
    submit) exit 0 ;;
    remove) rm -f "$S/submitted/$1"; exit 0 ;;
    limit|kickstart) exit 0 ;;
  esac; exit 0 ;;

pfctl)
  anchor=""; mode=""; file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -a) anchor="$2"; shift 2 ;;
      -n) mode="${mode}n"; shift ;;
      -f) file="$2"; mode="${mode}f"; shift 2 ;;
      -E) mode="${mode}E"; shift ;;
      -F) mode="${mode}F"; shift 2 ;;
      -s) mode="${mode}s$2"; shift 2 ;;
      -sr) mode="${mode}sr"; shift ;;
      -ss) mode="${mode}ss"; shift ;;
      *) shift ;;
    esac
  done
  case "$mode" in
    *sinfo) [ -e "$S/pf/enabled" ] && echo "Status: Enabled for 0 days 00:00:10           Debug: Urgent" || echo "Status: Disabled"; exit 0 ;;
    *n*f*) [ -s "$file" ] && grep -q '^block' "$file" && exit 0; echo "pfctl: syntax error in $file" >&2; exit 1 ;;
    *f) if [ -n "$anchor" ] && [ -e "$S/pf/fail-load" ]; then echo "pfctl: Syntax error (injected)" >&2; exit 1; fi
        if [ -n "$anchor" ]; then grep -E '^(pass|block)' "$file" > "$S/pf/anchor.rules"; touch "$S/pf/anchor.loaded"; else touch "$S/pf/wildcard"; fi; exit 0 ;;
    *E) touch "$S/pf/enabled"; exit 0 ;;
    *F) rm -f "$S/pf/anchor.rules" "$S/pf/anchor.loaded"; exit 0 ;;
    *sr) if [ -n "$anchor" ]; then [ -e "$S/pf/anchor.rules" ] && cat "$S/pf/anchor.rules"; else
           echo 'scrub-anchor "com.apple/*" all fragment reassemble'
           [ -e "$S/pf/wildcard" ] || [ ! -e "$S/pf/no-wildcard" ] && echo 'anchor "com.apple/*" all'; fi; exit 0 ;;
    *ss) [ -e "$S/pf/states" ] && cat "$S/pf/states"; exit 0 ;;
  esac; exit 0 ;;

dscl)
  shift
  case "$1" in
    -read) u="${2#/Users/}"; key="${3:-}"
           [ -e "$S/users/$u" ] || exit 56
           case "$key" in
             UniqueID) echo "UniqueID: 5$(( ${#u} ))1" ;;
             IsHidden) echo "IsHidden: $(cat "$S/users/$u/IsHidden" 2>/dev/null || echo 0)" ;;
             UserShell) echo "UserShell: $(cat "$S/users/$u/UserShell" 2>/dev/null || echo /bin/zsh)" ;;
             NFSHomeDirectory) echo "NFSHomeDirectory: /Users/$u" ;;
           esac; exit 0 ;;
    -create) u="${2#/Users/}"; mkdir -p "$S/users/$u"; printf '%s\n' "$4" > "$S/users/$u/$3"; exit 0 ;;
    -list) for u in "$S"/users/*; do echo "$(basename "$u") 5$(( ${#u} ))1"; done; exit 0 ;;
  esac; exit 0 ;;

dseditgroup)
  [ "$2" = checkmember ] && [ -e "$S/users/$4/admin" ] && exit 0; exit 67 ;;

pmset)
  if [ "${1:-}" = -g ]; then
    if [ "${2:-}" = custom ]; then echo "AC Power:"; sed 's/^/ /' "$S/pmset/state" 2>/dev/null; grep -q "^ *powermode " "$S/pmset/state" 2>/dev/null || echo " powermode 0"
    else sed -n 's/^ *disablesleep \(.*\)/ SleepDisabled\t\1/p' "$S/pmset/state" 2>/dev/null; echo " System-wide power settings:"; fi
    exit 0
  fi
  k="$2"; v="$3"
  touch "$S/pmset/state"; grep -v "^ *$k " "$S/pmset/state" > "$S/pmset/new"; echo " $k $v" >> "$S/pmset/new"; mv "$S/pmset/new" "$S/pmset/state"; exit 0 ;;

defaults)
  verb="$1"; dom="$(printf '%s' "$2" | tr '/ ' '__')"; key="$3"; mkdir -p "$S/defaults/$dom"
  case "$verb" in
    read) [ -e "$S/defaults/$dom/$key" ] && { cat "$S/defaults/$dom/$key"; exit 0; }; echo "The domain/default pair does not exist" >&2; exit 1 ;;
    write) case "${4:-}" in -bool) [ "$5" = false ] && echo 0 > "$S/defaults/$dom/$key" || echo 1 > "$S/defaults/$dom/$key" ;; *) echo "$4" > "$S/defaults/$dom/$key" ;; esac; exit 0 ;;
  esac; exit 0 ;;

mdutil)
  if [ "$1" = -s ]; then if [ -e "$S/spotlight-off" ]; then echo "/:"; echo "	Indexing disabled."; else echo "/:"; echo "	Indexing enabled."; fi; exit 0; fi
  touch "$S/spotlight-off"; exit 0 ;;

tmutil) touch "$S/tm-off"; echo 0 > "$S/defaults/_Library_Preferences_com.apple.TimeMachine_AutoBackup" 2>/dev/null; exit 0 ;;
fdesetup) echo "FileVault is Off."; exit 0 ;;
sw_vers) case "$1" in -buildVersion) echo 27A5001 ;; -productVersion) echo 27.0 ;; esac; exit 0 ;;
netstat) printf 'tcp4       0      0  *.22                   *.*                    LISTEN\n'; exit 0 ;;
lsof) echo 4242; exit 0 ;;
ps) echo /opt/homebrew/bin/ollama; exit 0 ;;
sshd) exit 0 ;;
visudo) exit 0 ;;
caffeinate) exit 0 ;;
sysctl)
  case "$1" in
    -n) if [ "${2:-}" = kern.boottime ]; then
          echo "{ sec = $(cat "$S/boottime" 2>/dev/null || echo 1700000000), usec = 0 } Tue Nov 14 22:13:20 2023"
        else cat "$S/iogpu" 2>/dev/null || echo 0; fi ;;
    -w) echo "${2#*=}" > "$S/iogpu" ;;
  esac; exit 0 ;;

brew)
  # the real brew accepts --formula anywhere; the toolkit passes it on list and install
  _a=(); for _x in "$@"; do [ "$_x" = --formula ] || _a+=("$_x"); done; set -- "${_a[@]}"
  case "$1" in
    list) if [ "$2" = --pinned ]; then cat "$S/brew/pinned" 2>/dev/null; exit 0; fi
          [ -e "$S/brew/$3" ] && { echo "$3 1.0"; exit 0; }; exit 1 ;;
    install) touch "$S/brew/$2"; mkdir -p /opt/homebrew/bin
             case "$2" in
               python@*) v="${2#python@}"; mkdir -p "/opt/homebrew/opt/$2/bin"
                         cp /var/lib/tockmox-sim-bin/python-shim "/opt/homebrew/opt/$2/bin/python$v" ;;
               llama.cpp) cp /var/lib/tockmox-sim-bin/generic "/opt/homebrew/bin/llama-server" ;;
               ollama) cp /var/lib/tockmox-sim-bin/ollama-shim /opt/homebrew/bin/ollama ;;
               hf) cp /var/lib/tockmox-sim-bin/hf-shim /opt/homebrew/bin/hf ;;
               *) cp /var/lib/tockmox-sim-bin/generic "/opt/homebrew/bin/$2" ;;
             esac; exit 0 ;;
    pin) echo "$2" >> "$S/brew/pinned"; exit 0 ;;
  esac; exit 0 ;;
esac
exit 0
