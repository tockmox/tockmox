#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Paste a documented block into an INTERACTIVE zsh on a pty, the way a macOS
terminal does: bracketed paste, then Enter. That is the only faithful way to
run a WORKSTATION block through the shell the docs name as supported ...
`zsh -c` and `zsh < file` both differ from a paste (no INTERACTIVE_COMMENTS
difference under -c; `read` swallows the next block line under stdin).

usage: zsh-paste.py BLOCKFILE [ANSWERFILE]
  ANSWERFILE lines are  PATTERN<TAB>ANSWER : when PATTERN appears in the
  output, ANSWER is typed followed by Enter (for `read -rs` prompts).
env:
  ZSH                   zsh binary (default: zsh on PATH)
  ZSH_PASTE_ZDOTDIR     ZDOTDIR with an empty .zshrc (isolates the run from the user's rc)
  ZSH_PASTE_TIMEOUT     seconds to wait for the block to return (default 600)
  ZSH_PASTE_INTERRUPT   seconds after which Ctrl-C is sent (for a `-w` watch; default: never)
  ZSH_PASTE_ENVOUT      file to receive `export -p` after the block (carry exports)
stdout: the transcript, control sequences stripped. exit status: the block's $?.
"""
import os, pty, sys, time, select, re, shutil
ZSH=os.environ.get("ZSH") or shutil.which("zsh") or "zsh"
TMO=float(os.environ.get("ZSH_PASTE_TIMEOUT","600"))
INT=float(os.environ.get("ZSH_PASTE_INTERRUPT","0") or 0)
ENVOUT=os.environ.get("ZSH_PASTE_ENVOUT","")
block=open(sys.argv[1]).read()
answers=[]
if len(sys.argv)>2:
    for l in open(sys.argv[2]).read().splitlines():
        if "\t" in l: p,a=l.split("\t",1); answers.append((p,a))
S1="__ZP_READY__"; S2="__ZP_RC__"
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="xterm"
    if os.environ.get("ZSH_PASTE_ZDOTDIR"): os.environ["ZDOTDIR"]=os.environ["ZSH_PASTE_ZDOTDIR"]
    os.execv(ZSH,[ZSH,"-i"])
def rd(until,tmo,also=None):
    buf=b""; end=time.time()+tmo
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try: c=os.read(fd,65536)
            except OSError: break
            if not c: break
            buf+=c
            if until in buf: return buf,"until"
            if also and also in buf: return buf,"also"
    return buf,None
os.write(fd,b"PS1=''; typeset -gi __zpn=0; precmd(){ (( __zpn++ )); print -n \"__ZP_READY_${__zpn}__ \"; }\r")
buf,_=rd(b"__ZP_READY_1__ ",10)
def nxt(n): return ("__ZP_READY_%d__ " % n).encode()
n=1
os.write(fd,b"\x1b[200~"+block.encode()+b"\x1b[201~\r")
trans=b""; start=time.time()
remaining=list(answers)
sent_int=False
while True:
    left=TMO-(time.time()-start)
    if left<=0: break
    step=min(left, 1.0)
    also=remaining[0][0].encode() if remaining else None
    chunk,why=rd(nxt(n+1),step,also)
    trans+=chunk
    if why=="also":
        # the prompt text may sit inside the terminal's echo of the block itself;
        # only answer once the echo is complete (the whole block seen twice), or
        # after a grace period if zle echoed it some other way
        _flat=re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]",b"",trans); _flat=re.sub(rb"\s+",b"",_flat)
        _wb=re.sub(rb"\s+",b"",block.encode())
        _after=_flat.rfind(_wb)
        _tail=_flat[_after+len(_wb):] if _after>=0 else b""
        if _flat.count(_wb)<2 and time.time()-start<3.0: continue
        if _after>=0 and re.sub(rb"\s+",b"",also) not in _tail: continue
    if why=="until": n+=1; break
    if why=="also":
        os.write(fd,remaining[0][1].encode()+b"\r"); remaining.pop(0); continue
    if INT and not sent_int and time.time()-start>INT:
        os.write(fd,b"\x03"); sent_int=True
os.write(fd,b"echo "+S2.encode()+b"=$?\r")
chunk,_=rd(nxt(n+1),10); trans+=chunk; n+=1
if ENVOUT:
    os.write(fd,b"export -p > "+ENVOUT.encode()+b"\r"); rd(nxt(n+1),10); n+=1
os.write(fd,b"exit\r")
try: os.waitpid(pid,0)
except Exception: pass
txt=trans.decode("utf-8","replace").replace("\r\n","\n").replace("\r","")
txt=re.sub(r"\x1b\[[0-9;?]*[A-Za-z]","",txt)
txt=re.sub(r"\x1b[=>78]","",txt)          # keypad / cursor save-restore, two-byte ESC sequences
txt=re.sub(r"\x1b\][^\x07]*\x07","",txt)  # OSC (title) sequences
m=re.search(S2+r"=(\d+)",txt); rc=int(m.group(1)) if m else 255
if ENVOUT and (ENVOUT in txt):
    txt=re.sub(r"export -p > "+re.escape(ENVOUT)+r"\n?","",txt)
txt=re.sub(r"echo "+S2+r"=\$\?\n?","",txt); txt=re.sub(S2+r"=\d+\n?","",txt)
txt=re.sub(r"__ZP_READY_\d+__ ","",txt)
def _norm(s): return re.sub(r"\s+","",s)
# The terminal echoes the pasted buffer (zle may redraw it wrapped, split, or
# joined) BEFORE anything executes. Cut everything up to the end of that echo:
# find the block's last line, whitespace-normalised, in the whitespace-
# normalised transcript, and map the match end back to a transcript offset.
lines=[l for l in block.rstrip("\n").split("\n") if l.strip()]
if lines:
    last=_norm(lines[-1])
    idx=[i for i,ch in enumerate(txt) if not ch.isspace()]
    flat="".join(txt[i] for i in idx)
    whole=_norm(block)
    # zle echoes the buffer twice: highlighted on paste, then plain on accept.
    # The LAST occurrence of the whole block is the end of the echo.
    j=flat.rfind(whole); n=len(whole)
    if j<0: j=flat.find(last); n=len(last)
    if j>=0:
        cut=idx[j+n-1]+1
        txt=txt[cut:]
out=[]
for l in txt.split("\n"):
    s=l.strip()
    if not s or re.fullmatch(r"(%\s*)+e?%?\s*",s) or "unsetopt beep" in s: continue
    out.append(l)
txt="\n".join(out)
sys.stdout.write(txt+("\n" if txt else ""))
sys.exit(rc)
