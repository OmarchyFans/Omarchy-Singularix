#!/bin/bash
# Scripted answers for the form. Each prompt pops the next line of $OAL_ANSWERS
# (a file). choose() picks the option whose first word matches the answer;
# choose_many() takes a comma-separated list. Everything is logged so a test
# can assert what the user was asked.
_answer() {
  local a; IFS= read -r a <"$OAL_ANSWERS" || { echo "stub: out of answers for: $1" >&2; exit 99; }
  sed -i '1d' "$OAL_ANSWERS"
  printf '%s\t%s\n' "$1" "$a" >>"$OAL_ASKED"
  printf '%s' "$a"
}
choose() {
  local want; want=$(_answer "choose: $1"); shift
  local o; for o in "$@"; do [[ ${o%% *} == "$want" || $o == "$want" ]] && { printf '%s\n' "$o"; return; }; done
  echo "stub: no option '$want' among: $*" >&2; exit 98
}
choose_many() { local a; a=$(_answer "choose_many: $1"); tr ',' '\n' <<<"$a" | sed '/^$/d'; }
ask()        { _answer "ask: $1"; echo; }
ask_secret() { _answer "secret: $1"; echo; }
confirm()    { [[ $(_answer "confirm: $1") == y ]]; }
title()      { printf '== %s\n' "$1"; }
