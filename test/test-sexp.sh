#!/bin/bash
#
# test-sexp.sh — Validate slash grammar by checking s-expression output
#
# Usage: ./test/test-sexp.sh [path/to/slash]
#
# Each test: input string → expected s-expression output
# Exits 0 if all pass, 1 if any fail.

SLASH="${1:-bin/slash}"
PASS=0
FAIL=0
ERRORS=""

check() {
    local label="$1"
    local input="$2"
    local expect="$3"
    local actual
    actual=$("$SLASH" -s -c "$input" 2>&1)
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: ${label}\n    input:  ${input}\n    expect: ${expect}\n    actual: ${actual}\n"
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
check "bare command"            "ls"                        "(cmd ls)"
check "command with flag"       "ls -la"                    "(cmd ls -la)"
check "command with args"       "ls -la /tmp"               "(cmd ls -la /tmp)"
check "command with string"     'echo "hello world"'        '(cmd echo "hello world")'
check "multi-word command"      "git commit -m initial"     "(cmd git commit -m initial)"

# ---------------------------------------------------------------------------
# Assignment and math
# ---------------------------------------------------------------------------
check "assign integer"          "x = 42"                    "(assign x 42)"
check "assign string"           'name = "steve"'            '(assign name "steve")'
check "assign addition"         "x = 10 + 4"               "(assign x (add 10 4))"
check "assign subtraction"      "x = 10 - 3"               "(assign x (sub 10 3))"
check "assign multiply"         "x = 3 * 7"                "(assign x (mul 3 7))"
check "assign division"         "x = 10 / 2"               "(assign x (div 10 2))"
check "assign modulo"           "x = 10 % 3"               "(assign x (mod 10 3))"
check "assign power"            "x = 2 ** 8"               "(assign x (pow 2 8))"
check "assign negative"         "x = -5"                    "(assign x (neg 5))"
check "precedence mul+add"      "x = 2 + 3 * 4"            "(assign x (add 2 (mul 3 4)))"
check "precedence parens"       "x = (1 + 2) * 3"          "(assign x (mul (add 1 2) 3))"
check "assign default"          'x = $y ?? 0'               "(assign x (default \$y 0))"
check "assign capture"          'x = $(ls)'                 "(assign x (capture (cmd ls)))"
check "unset variable"          "name = -"                  "(unset name)"

# ---------------------------------------------------------------------------
# Pipelines
# ---------------------------------------------------------------------------
check "simple pipe"             "ls | wc"                   "(pipe (cmd ls) (cmd wc))"
check "multi pipe"              "ls | grep zig | sort"      "(pipe (cmd ls) (pipe (cmd grep zig) (cmd sort)))"
check "pipe stderr"             "make |& grep error"        "(pipe_err (cmd make) (cmd grep error))"

# ---------------------------------------------------------------------------
# Boolean operators (symbol and word forms)
# ---------------------------------------------------------------------------
check "&& symbol"               "make && echo done"         "(and (cmd make) (cmd echo done))"
check "and keyword"             "make and echo done"        "(and (cmd make) (cmd echo done))"
check "|| symbol"               "make || echo fail"         "(or (cmd make) (cmd echo fail))"
check "or keyword"              "make or echo fail"         "(or (cmd make) (cmd echo fail))"
check "! symbol"                "! ls"                      "(not (cmd ls))"
check "not keyword"             "not ls"                    "(not (cmd ls))"

# ---------------------------------------------------------------------------
# Semicolons and background
# ---------------------------------------------------------------------------
check "semicolon"               "a ; b"                     "(seq (cmd a) (cmd b))"
check "background"              "sleep 10 &"                "(bg (cmd sleep 10))"
check "background + next"       "make & echo watching"      "(bg (cmd make) (cmd echo watching))"

# ---------------------------------------------------------------------------
# Redirections
# ---------------------------------------------------------------------------
check "redirect out"            "ls > out.txt"              "(cmd ls (redir_out out.txt))"
check "redirect append"         "ls >> out.txt"             "(cmd ls (redir_append out.txt))"
check "redirect in"             "cat < in.txt"              "(cmd cat (redir_in in.txt))"
check "redirect stderr"         "app 2> err.txt"            "(cmd app (redir_err err.txt))"
check "redirect both"           "app &> all.txt"            "(cmd app (redir_both all.txt))"
check "redirect dup"            "ls > out.txt 2>&1"         "(cmd ls (redir_out out.txt) (redir_dup))"
check "herestring"              'wc <<< "hello"'            '(cmd wc (herestring "hello"))'

# ---------------------------------------------------------------------------
# Subshell, capture, process substitution
# ---------------------------------------------------------------------------
check "subshell"                "(cd /tmp ; ls)"            "(subshell (seq (cmd cd /tmp) (cmd ls)))"
check "capture in cmd"          'echo $(ls)'                "(cmd echo (capture (cmd ls)))"
check "process sub in"          "diff <(sort a) <(sort b)"  "(cmd diff (procsub_in (cmd sort a)) (procsub_in (cmd sort b)))"

# ---------------------------------------------------------------------------
# Conditionals: if / unless / else
# ---------------------------------------------------------------------------
check "if pipeline"             "if ls { echo yes }"                    "(if (cmd ls) (block (cmd echo yes)))"
check "if with test"            "if test -f foo { echo y }"             "(if (test -f foo) (block (cmd echo y)))"
check "unless"                  "unless ls { echo no }"                 "(unless (cmd ls) (block (cmd echo no)))"
check "if/else"                 "if ls { echo y } else { echo n }"     "(if (cmd ls) (block (cmd echo y)) (else (block (cmd echo n))))"
check "if comparison"           'if $x == 1 { echo one }'              "(if (eq \$x 1) (block (cmd echo one)))"
check "if not-equal"            'if $x != 0 { echo nz }'               "(if (ne \$x 0) (block (cmd echo nz)))"
check "if bool and"             'if $x > 0 and $x < 100 { echo r }'    "(if (and (gt \$x 0) (lt \$x 100)) (block (cmd echo r)))"
check "if not cmp"              'if not $x == 0 { echo nz }'           "(if (not (eq \$x 0)) (block (cmd echo nz)))"
check "if cmd and cmd"          "if test -d a and test -f b { echo y }" "(if (and (test -d a) (test -f b)) (block (cmd echo y)))"
check "if cmd && cmd"           "if ls && test -f a { echo y }"         "(if (and (cmd ls) (test -f a)) (block (cmd echo y)))"

# ---------------------------------------------------------------------------
# Loops: for / while / until
# ---------------------------------------------------------------------------
check "for loop"                "for f in a b c { echo f }" "(for f (list a b c) (block (cmd echo f)))"
check "while loop"              "while true { echo y }"     "(while (cmd true) (block (cmd echo y)))"

# ---------------------------------------------------------------------------
# Pattern matching: try
# ---------------------------------------------------------------------------
check "try with arms"           'try $x { "a" { echo a } "b" { echo b } }' '(try $x ((arm "a" (block (cmd echo a))) (arm "b" (block (cmd echo b)))))'

# ---------------------------------------------------------------------------
# Nested constructs
# ---------------------------------------------------------------------------
check "nested if in for"        'for f in a b c { if test -f $f { echo $f } }' '(for f (list a b c) (block (if (test -f $f) (block (cmd echo $f)))))'

# ---------------------------------------------------------------------------
# User commands: cmd
# ---------------------------------------------------------------------------
check "cmd define one-line"     "cmd g ls"                  "(cmd_def g _ (cmd ls))"
check "cmd delete"              "cmd foo -"                 "(cmd_del foo)"
check "cmd show"                "cmd foo"                   "(cmd_show foo)"
check "cmd list"                "cmd"                       "(cmd_list)"

# ---------------------------------------------------------------------------
# Key bindings
# ---------------------------------------------------------------------------
check "key define"              'key esc-l "ls -la"'        '(key esc-l "ls -la")'
check "key delete"              "key esc-l -"               "(key_del esc-l)"

# ---------------------------------------------------------------------------
# Shell options: set
# ---------------------------------------------------------------------------
check "set option"              "set foo bar"               "(set foo bar)"
check "set reset"               "set foo -"                 "(set_reset foo)"
check "set show"                "set foo"                   "(set_show foo)"
check "set list"                "set"                       "(set_list)"

# ---------------------------------------------------------------------------
# Special builtins
# ---------------------------------------------------------------------------
check "test flag"               "test -f foo"               "(test -f foo)"
check "exit"                    "exit 1"                    "(exit 1)"
check "exit no arg"             "exit"                      "(exit)"
check "shift"                   "shift"                     "(shift)"
check "break"                   "break"                     "(break)"
check "continue"                "continue"                  "(continue)"
check "source"                  "source file.slash"         "(source file.slash)"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed ($(( PASS + FAIL )) total)"
if [ "$FAIL" -gt 0 ]; then
    printf "$ERRORS"
    exit 1
fi
