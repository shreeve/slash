#!/bin/bash
#
# runner.sh — Slash grammar test suite
#
# Usage: ./test/runner.sh [path/to/slash]
#
# Validates the grammar by checking s-expression output for each input.
# Exits 0 if all pass, 1 if any fail.

SLASH="${1:-bin/slash}"
PASS=0
FAIL=0
ERRORS=""

check() {
    local label="$1"
    local input="$2"
    local expect_sexp="$3"
    local expect_exec="${4:-}"
    local actual

    # Test 1: s-expression output (skip if expect is empty)
    if [ -n "$expect_sexp" ]; then
        actual=$("$SLASH" -s -c "$input" 2>&1)
        if [ "$actual" = "$expect_sexp" ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: ${label} [sexp]\n    input:  ${input}\n    expect: ${expect_sexp}\n    actual: ${actual}\n"
        fi
    fi

    # Test 2: execution output (if expected output provided)
    if [ -n "$expect_exec" ]; then
        actual=$("$SLASH" -c "$input" 2>/dev/null)
        if [ "$actual" = "$expect_exec" ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: ${label} [exec]\n    input:  ${input}\n    expect: ${expect_exec}\n    actual: ${actual}\n"
        fi
    fi
}

# ==========================================================================
# COMMANDS
# ==========================================================================
check "bare command"            "ls"                        "(cmd ls)"
check "command with flag"       "ls -la"                    "(cmd ls -la)"
check "command with args"       "ls -la /tmp"               "(cmd ls -la /tmp)"
check "command with string"     'echo "hello world"'        '(cmd echo "hello world")'    "hello world"
check "command with sq string"  "echo 'hello'"              "(cmd echo 'hello')"          "hello"
check "multi-word command"      "git commit -m initial"     "(cmd git commit -m initial)"
check "long flag"               "ls --verbose"              "(cmd ls --verbose)"
check "path-like arg"           "cat /etc/hosts"            "(cmd cat /etc/hosts)"
check "dotpath arg"             "ls ./src"                  "(cmd ls ./src)"
check "tilde arg"               "cd ~/projects"             "(cmd cd ~/projects)"

# ==========================================================================
# VARIABLES IN COMMANDS
# ==========================================================================
check "variable arg"            'echo $HOME'                '(cmd echo $HOME)'           "$HOME"
check "variable special ?"      'echo $?'                   '(cmd echo $?)'              "0"
check "variable special $$"     'echo $$'                   '(cmd echo $$)'
check "variable positional"     'echo $1'                   '(cmd echo $1)'
check "variable braced"         'echo ${name}'              '(cmd echo ${name})'

# ==========================================================================
# DISPLAY (= expr)
# ==========================================================================
check "display add"             "= 1 + 3"                   "(display (add 1 3))"         "4"
check "display sub"             "= 10 - 3"                  "(display (sub 10 3))"        "7"
check "display mul"             "= 3 * 7"                   "(display (mul 3 7))"         "21"
check "display div"             "= 22 / 7"                  "(display (div 22 7))"        "3.1428571429"
check "display mod"             "= 100 % 7"                 "(display (mod 100 7))"       "2"
check "display power"           "= 2 ** 8"                  "(display (pow 2 8))"         "256"
check "display neg"             "= -5"                      "(display (neg 5))"           "-5"
check "display parens"          "= (1 + 2) * 3"             "(display (mul (add 1 2) 3))" "9"
check "display precedence"      "= 2 + 3 * 4"               "(display (add 2 (mul 3 4)))" "14"
check "display default"         '= $x ?? 0'                 "(display (default \$x 0))"   "0"
check "display variable"        '= $x + 1'                  "(display (add \$x 1))"       "1"
check "display float"           "= 3.14"                    "(display 3.14)"              "3.14"
check "display capture"         '= $(ls)'                   "(display (capture (cmd ls)))"

# ==========================================================================
# ASSIGNMENT AND MATH
# ==========================================================================
check "assign integer"          "x = 42"                    "(assign x 42)"
check "assign string"           'name = "steve"'            '(assign name "steve")'
check "assign sq string"        "name = 'steve'"            "(assign name 'steve')"
check "assign addition"         "x = 10 + 4"                "(assign x (add 10 4))"
check "assign subtraction"      "x = 10 - 3"                "(assign x (sub 10 3))"
check "assign multiply"         "x = 3 * 7"                 "(assign x (mul 3 7))"
check "assign division"         "x = 10 / 2"                "(assign x (div 10 2))"
check "assign modulo"           "x = 10 % 3"                "(assign x (mod 10 3))"
check "assign power"            "x = 2 ** 8"                "(assign x (pow 2 8))"
check "assign negative"         "x = -5"                    "(assign x (neg 5))"
check "assign float"            "x = 3.14"                  "(assign x 3.14)"
check "precedence mul+add"      "x = 2 + 3 * 4"             "(assign x (add 2 (mul 3 4)))"
check "precedence parens"       "x = (1 + 2) * 3"           "(assign x (mul (add 1 2) 3))"
check "assign default"          'x = $y ?? 0'               "(assign x (default \$y 0))"
check "assign capture"          'x = $(ls)'                 "(assign x (capture (cmd ls)))"
check "match rhs expr paren"    'if $x =~ (1) { echo yes }' "(if (match \$x 1) (block (cmd echo yes)))"
check "nomatch rhs expr var"    'if $x !~ $y { echo no }'   "(if (nomatch \$x \$y) (block (cmd echo no)))"
check "unset variable"          "name = -"                  "(unset name)"
check "assign list literal"     'args = [find .]'           "(assign_argv args (list find .))"
check "append list literal"     'args += [-iname "*foo*"]'  '(append_argv args (list -iname "*foo*"))'
check "assign empty list"       'args = []'                 "(assign_argv args (list))"

# ==========================================================================
# PIPELINES
# ==========================================================================
check "simple pipe"             "ls | wc"                   "(pipe (cmd ls) (cmd wc))"
check "multi pipe"              "ls | grep zig | sort"      "(pipe (cmd ls) (pipe (cmd grep zig) (cmd sort)))"
check "pipe stderr"             "make |& grep error"        "(pipe_err (cmd make) (cmd grep error))"
check "pipe stderr exec"        '/bin/sh -c "echo out; echo err 1>&2" |& wc -l' "" "       2"
check "4-stage pipe exec"       'echo hello world | tr h H | tr w W | wc -w' "" "       2"
check "10-stage pipe exec"      'echo hello | cat | cat | cat | cat | cat | cat | cat | cat | cat | wc -w' "" "       1"
check "mixed pipe err exec"     '/bin/sh -c "echo out; echo err 1>&2" |& cat | wc -l' "" "       2"

# ==========================================================================
# BOOLEAN OPERATORS (symbol and word forms)
# ==========================================================================
check "&& symbol"               "make && echo done"         "(and (cmd make) (cmd echo done))"
check "and keyword"             "make and echo done"        "(and (cmd make) (cmd echo done))"
check "|| symbol"               "make || echo fail"         "(or (cmd make) (cmd echo fail))"
check "or keyword"              "make or echo fail"         "(or (cmd make) (cmd echo fail))"
check "! symbol"                "! ls"                      "(not (cmd ls))"
check "not keyword"             "not ls"                    "(not (cmd ls))"
check "xor keyword"             "a xor b"                   "(xor (cmd a) (cmd b))"
check "! with args"             "! echo fail"               "(not (cmd echo fail))"       "fail"
check "not with args"           "not echo fail"             "(not (cmd echo fail))"       "fail"

# ==========================================================================
# SEMICOLONS AND BACKGROUND
# ==========================================================================
check "semicolon"               "a ; b"                     "(seq (cmd a) (cmd b))"
check "semicolon three"         "a ; b ; c"                 "(seq (cmd a) (seq (cmd b) (cmd c)))"
check "background"              "sleep 10 &"                "(bg (cmd sleep 10))"
check "background + next"       "make & echo watching"      "(bg (cmd make) (cmd echo watching))"
check "wait last pid exit"      'false & wait $! ; echo $?'  ""                        "1"
check "wait all children"       'true & wait ; echo ok'      ""                        "ok"

# ==========================================================================
# REDIRECTIONS
# ==========================================================================
check "redirect out"            "ls > out.txt"              "(cmd ls (redir_out out.txt))"
check "redirect append"         "ls >> out.txt"             "(cmd ls (redir_append out.txt))"
check "redirect in"             "cat < in.txt"              "(cmd cat (redir_in in.txt))"
check "redirect stderr"         "app 2> err.txt"            "(cmd app (redir_err err.txt))"
check "redirect stderr app"     "app 2>> err.log"           "(cmd app (redir_err_app err.log))"
check "redirect both"           "app &> all.txt"            "(cmd app (redir_both all.txt))"
check "redirect dup"            "ls > out.txt 2>&1"         "(cmd ls (redir_out out.txt) (redir_dup))"
check "redirect to devnull"     "echo hello > /dev/null"    "(cmd echo hello (redir_out /dev/null))"
check "herestring"              'wc <<< "hello"'            '(cmd wc (herestring "hello"))'       "       1       1       6"
check "herestring variable"     'cat <<< $name'             '(cmd cat (herestring $name))'

# ==========================================================================
# SUBSHELL, CAPTURE, PROCESS SUBSTITUTION
# ==========================================================================
check "subshell"                "(cd /tmp ; ls)"            "(subshell (seq (cmd cd /tmp) (cmd ls)))"
check "subshell pipeline"       "(ls | wc)"                 "(subshell (pipe (cmd ls) (cmd wc)))"
check "capture in cmd"          'echo $(echo captured)'     "(cmd echo (capture (cmd echo captured)))"  "captured"
check "capture pipeline"        'echo $(ls | wc)'           "(cmd echo (capture (pipe (cmd ls) (cmd wc))))"
check "process sub in"          "diff <(sort a) <(sort b)"  "(cmd diff (procsub_in (cmd sort a)) (procsub_in (cmd sort b)))"
check "process sub same"        "diff <(echo x) <(echo x)"  "(cmd diff (procsub_in (cmd echo x)) (procsub_in (cmd echo x)))"  ""
check "process sub out"         "tee >(wc)"                 "(cmd tee (procsub_out (cmd wc)))"

# ==========================================================================
# CONDITIONALS: if / unless / else
# ==========================================================================
check "if pipeline"             "if true { echo yes }"                  "(if (cmd true) (block (cmd echo yes)))"    "yes"
check "if false"                "if false { echo y } else { echo n }"   "(if (cmd false) (block (cmd echo y)) (else (block (cmd echo n))))"  "n"
check "if with test"            "if test -f build.zig { echo y }"       "(if (test -f build.zig) (block (cmd echo y)))"  "y"
check "unless true"             "unless false { echo yes }"             "(unless (cmd false) (block (cmd echo yes)))"    "yes"
check "if/else"                 "if true { echo y } else { echo n }"    "(if (cmd true) (block (cmd echo y)) (else (block (cmd echo n))))"   "y"
check "if/else if/else"         "if false { echo a } else if true { echo b } else { echo c }" "(if (cmd false) (block (cmd echo a)) (if (cmd true) (block (cmd echo b)) (else (block (cmd echo c)))))"  "b"

# --- comparison operators ---
check "if ==" 'if $x == 1 { echo y }'         "(if (eq \$x 1) (block (cmd echo y)))"
check "if !=" 'if $x != 0 { echo y }'         "(if (ne \$x 0) (block (cmd echo y)))"
check "if <"  'if $x < 10 { echo y }'         "(if (lt \$x 10) (block (cmd echo y)))"
check "if >"  'if $x > 10 { echo y }'         "(if (gt \$x 10) (block (cmd echo y)))"
check "if <=" 'if $x <= 10 { echo y }'        "(if (le \$x 10) (block (cmd echo y)))"
check "if >=" 'if $x >= 10 { echo y }'        "(if (ge \$x 10) (block (cmd echo y)))"
check "cmp var==var" 'if $a == $b { echo y }' "(if (eq \$a \$b) (block (cmd echo y)))"
check "cmp var>var"  'if $x > $y { echo y }'  "(if (gt \$x \$y) (block (cmd echo y)))"

# --- boolean logic in conditions ---
check "cmp and"                'if $x > 0 and $x < 100 { echo r }'     "(if (and (gt \$x 0) (lt \$x 100)) (block (cmd echo r)))"
check "cmp or"                 'if $x == 1 or $x == 2 { echo y }'      "(if (or (eq \$x 1) (eq \$x 2)) (block (cmd echo y)))"
check "cmp not"                'if not $x == 0 { echo nz }'            "(if (not (eq \$x 0)) (block (cmd echo nz)))"
check "cmp grouped"            'if ($a == 1 or $b == 2) and $c == 3 { echo y }' "(if (and (or (eq \$a 1) (eq \$b 2)) (eq \$c 3)) (block (cmd echo y)))"
check "cmd and cmd"            "if test -d a and test -f b { echo y }" "(if (and (test -d a) (test -f b)) (block (cmd echo y)))"
check "cmd && cmd"             "if ls && test -f a { echo y }"         "(if (and (cmd ls) (test -f a)) (block (cmd echo y)))"

# ==========================================================================
# LOOPS: for / while / until
# ==========================================================================
check "for loop"               "for f in a b c { echo f }" "(for f (list a b c) (block (cmd echo f)))"
check "for many words"         "for f in a b c d e { echo f }" "(for f (list a b c d e) (block (cmd echo f)))"
check "while loop"             "while true { echo y }"     "(while (cmd true) (block (cmd echo y)))"
check "until loop"             "until true { echo y }"     "(until (cmd true) (block (cmd echo y)))"

# ==========================================================================
# PATTERN MATCHING: try
# ==========================================================================
check "try with arms"          'try $x { "a" { echo a } "b" { echo b } }'  '(try $x ((arm "a" (block (cmd echo a))) (arm "b" (block (cmd echo b)))))'
check "try with else"          'try $x { "a" { echo a } else { echo z } }' '(try $x ((arm "a" (block (cmd echo a))) (arm_else (block (cmd echo z)))))'
check "try shift value"        'try shift { "a" { echo y } else { echo n } }' '(try (shift_value shift) ((arm "a" (block (cmd echo y))) (arm_else (block (cmd echo n)))))'
check "try regex exec"         'try "test" { /te.*/ { echo yes } else { echo no } }' "" "yes"

# ==========================================================================
# NESTED CONSTRUCTS
# ==========================================================================
check "nested if in for"       'for f in a b c { if test -f $f { echo $f } }' '(for f (list a b c) (block (if (test -f $f) (block (cmd echo $f)))))'
check "pipe in subshell"       "(ls | sort)"                   "(subshell (pipe (cmd ls) (cmd sort)))"
check "redir in if block"      "if ls { echo ok > /dev/null }" "(if (cmd ls) (block (cmd echo ok (redir_out /dev/null))))"

# ==========================================================================
# USER COMMANDS: cmd
# ==========================================================================
check "cmd define one-line"    "cmd g ls"                   "(cmd_def g _ (cmd ls))"
check "cmd define with args"   "cmd g git status"           "(cmd_def g _ (cmd git status))"
check "cmd delete"             "cmd foo -"                  "(cmd_del foo)"
check "cmd show"               "cmd foo"                    "(cmd_show foo)"
check "cmd list"               "cmd"                        "(cmd_list)"
check "cmd ??? define"         'cmd ??? { echo missing }'   "(cmd_missing _ (block (cmd echo missing)))"
check "cmd ??? show"           "cmd ???"                    "(cmd_missing_show)"
check "cmd ??? delete"         "cmd ??? -"                  "(cmd_missing_del)"

# ==========================================================================
# KEY BINDINGS
# ==========================================================================
check "key define string"      'key esc-l "ls -la"'         '(key esc-l "ls -la")'
check "key define action"      "key esc-l dirs"             "(key esc-l dirs)"
check "key define esc-equals"  "key esc-= j"                "(key (key_combo_eq esc-) j)"
check "key delete"             "key esc-l -"                "(key_del esc-l)"

# ==========================================================================
# SHELL OPTIONS: set
# ==========================================================================
check "set option"             "set foo=bar"                "(set foo bar)"
check "set option spaced eq"   "set foo = bar"              "(set foo bar)"
check "set option true"        "set prompt-git=true"        "(set prompt-git true)"
check "set reset"              "set foo -"                  "(set_reset foo)"
check "set show"               "set foo"                    "(set_show foo)"
check "set list"               "set"                        "(set_list)"

# ==========================================================================
# SPECIAL BUILTINS
# ==========================================================================
check "test -f"                "test -f foo"                "(test -f foo)"
check "test -d"                "test -d src"                "(test -d src)"
check "test -e"                "test -e /tmp"               "(test -e /tmp)"
check "exit code"              "exit 1"                     "(exit 1)"
check "exit no arg"            "exit"                       "(exit)"
check "shift"                  "shift"                      "(cmd shift)"
check "shift count"            "shift 2"                    "(cmd shift 2)"
check "break"                  "break"                      "(break)"
check "continue"               "continue"                   "(continue)"
check "source"                 "source file.slash"          "(source file.slash)"
check "exec"                   "exec ls -la"                "(exec (cmd ls -la))"

# ==========================================================================
# COMBINED / EDGE CASES
# ==========================================================================

# --- multiple redirections on one command ---
check "multi redir"            "app > out.txt 2> err.txt"       "(cmd app (redir_out out.txt) (redir_err err.txt))"
check "redir + append"         "app > out.txt 2>> err.log"      "(cmd app (redir_out out.txt) (redir_err_app err.log))"

# --- pipes with redirections ---
check "pipe + redir"           "ls | sort > out.txt"            "(pipe (cmd ls) (cmd sort (redir_out out.txt)))"
check "pipe + herestring"      'sort <<< "c b a"'               '(cmd sort (herestring "c b a"))'

# --- background with pipes ---
check "bg pipeline"            "ls | sort &"                    "(bg (pipe (cmd ls) (cmd sort)))"

# --- negation with pipeline ---
check "not pipeline"           "! ls | wc"                      "(pipe (not (cmd ls)) (cmd wc))"

# --- for with variable words ---
check "for with vars"          'for f in $a $b $c { echo $f }'  '(for f (list $a $b $c) (block (cmd echo $f)))'

# --- while with comparison ---
check "while comparison"       'while $x < 10 { echo $x }'      "(while (lt \$x 10) (block (cmd echo \$x)))"

# --- nested captures ---
check "nested capture"         'echo $(echo $(date))'           "(cmd echo (capture (cmd echo (capture (cmd date)))))"

# --- cmd with block ---
check "cmd with block"         "cmd foo { echo hi }"            "(cmd_def foo _ (block (cmd echo hi)))"
check "cmd with args body"     'cmd g git status'               "(cmd_def g _ (cmd git status))"

# --- chained boolean ---
check "chain &&"               "a && b && c"                    "(and (cmd a) (and (cmd b) (cmd c)))"
check "chain ||"               "a || b || c"                    "(or (cmd a) (or (cmd b) (cmd c)))"
check "mixed && ||"            "a && b || c"                    "(and (cmd a) (or (cmd b) (cmd c)))"
check "mixed ; &&"             "a ; b && c"                     "(seq (cmd a) (and (cmd b) (cmd c)))"

# --- display edge cases ---
check "display nested parens"  "= ((1 + 2))"                    "(display (add 1 2))"
check "display var math"       '= $x * 2'                       "(display (mul \$x 2))"
check "display positive"       "= +5"                           "(display 5)"
check "display double neg"     "= -(-3)"                        "(display (neg (neg 3)))"

# --- subshell with boolean ---
check "subshell &&"            "(a && b)"                       "(subshell (and (cmd a) (cmd b)))"
check "subshell ||"            "(a || b)"                       "(subshell (or (cmd a) (cmd b)))"

# --- redir in if ---
check "redir in if block"     "if ls { echo ok > /dev/null }"   "(if (cmd ls) (block (cmd echo ok (redir_out /dev/null))))"

# --- capture in assignment ---
check "assign capture pipe"   'x = $(ls | wc -l)'               "(assign x (capture (pipe (cmd ls) (cmd wc -l))))"

# ==========================================================================
# HEREDOCS (multi-line, use script files)
# ==========================================================================

check_script() {
    local label="$1"
    local script="$2"
    local expect="$3"
    local actual
    local tmpf="/tmp/_slash_test_$$.slash"
    printf '%s\n' "$script" > "$tmpf"
    actual=$("$SLASH" "$tmpf" 2>/dev/null)
    rm -f "$tmpf"
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: ${label}\n    expect: ${expect}\n    actual: ${actual}\n"
    fi
}

check_script_args() {
    local label="$1"
    local script="$2"
    local expect="$3"
    shift 3
    local actual
    local tmpf="/tmp/_slash_test_args_$$.slash"
    printf '%s\n' "$script" > "$tmpf"
    actual=$("$SLASH" "$tmpf" "$@" 2>/dev/null)
    rm -f "$tmpf"
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: ${label}\n    expect: ${expect}\n    actual: ${actual}\n"
    fi
}

check_script_raw() {
    local label="$1"
    local script="$2"
    local expect="$3"
    local actual
    local tmpf="/tmp/_slash_test_raw_$$.slash"
    printf '%s' "$script" > "$tmpf"
    actual=$("$SLASH" "$tmpf" 2>/dev/null)
    rm -f "$tmpf"
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: ${label}\n    expect: ${expect}\n    actual: ${actual}\n"
    fi
}

check_script_all() {
    local label="$1"
    local script="$2"
    local expect="$3"
    local actual
    local tmpf="/tmp/_slash_test_all_$$.slash"
    printf '%s\n' "$script" > "$tmpf"
    actual=$("$SLASH" "$tmpf" 2>&1)
    rm -f "$tmpf"
    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: ${label}\n    expect: ${expect}\n    actual: ${actual}\n"
    fi
}

check_script_error() {
    local label="$1"
    local script="$2"
    local actual
    local tmpf="/tmp/_slash_test_err_$$.slash"
    printf '%s\n' "$script" > "$tmpf"
    actual=$("$SLASH" "$tmpf" 2>&1 || true)
    rm -f "$tmpf"
    case "$actual" in
        *"invalid syntax"*)
            PASS=$((PASS + 1))
            ;;
        *)
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: ${label}\n    expect invalid syntax\n    actual: ${actual}\n"
            ;;
    esac
}

check_script "heredoc literal" \
    "$(printf "cat '''\n    hello world\n    '''\n")" \
    "hello world"

check_script "heredoc multi-line" \
    "$(printf "cat '''\n    line 1\n    line 2\n    '''\n")" \
    "$(printf 'line 1\nline 2')"

check_script "heredoc margin strip" \
    "$(printf "cat '''\n        indented\n    '''\n")" \
    "    indented"

check_script "heredoc pipe closing" \
    "$(printf "cat '''\n    hello\n    ''' | wc -l\n")" \
    "       1"

check_script "heredoc pipe opening" \
    "$(printf "cat ''' | wc -l\n    hello\n    '''\n")" \
    "       1"

check_script "heredoc interpolated" \
    "$(printf 'cat \"\"\"\n    hello\n    \"\"\"\n')" \
    "hello"

# ==========================================================================
# EXECUTION: MULTI-LINE SCRIPTS
# ==========================================================================

check_script "exec assign + echo" \
    "$(printf 'x = 10 + 4\necho $x\n')" \
    "14"

check_script "exec assign + math" \
    "$(printf 'x = 2 ** 8\necho $x\n')" \
    "256"

check_script "exec clear variable" \
    "$(printf '__slash_test_clear_var__ = hello\n__slash_test_clear_var__ = -\necho $__slash_test_clear_var__\n')" \
    ""

check_script "exec for loop" \
    "$(printf 'for f in a b c { echo $f }\n')" \
    "$(printf 'a\nb\nc')"

check_script "exec if true" \
    "$(printf 'if true { echo yes }\n')" \
    "yes"

check_script "exec if false else" \
    "$(printf 'if false { echo y } else { echo n }\n')" \
    "n"

check_script_raw "exec no trailing newline" \
    'echo no-newline' \
    "no-newline"

check_script_error "exec malformed dedent" \
    "$(printf 'if true\n    echo yes\n  echo bad\n')"

check_script_all "exec jobspec shorthand invalid syntax" \
    "$(printf '%%3\n')" \
    "invalid syntax"

check_script_all "exec single question invalid syntax" \
    "$(printf '?\n')" \
    "invalid syntax"

check_script "exec indent if else" \
    "$(printf 'if true\n    echo yes\nelse\n    echo no\n')" \
    "yes"

check_script "exec unless" \
    "$(printf 'unless false { echo ok }\n')" \
    "ok"

check_script "exec redirect" \
    "$(printf 'echo hello > /tmp/_slash_redir_test.txt\ncat /tmp/_slash_redir_test.txt\n')" \
    "hello"

check_script "exec pipe" \
    "$(printf 'echo hello world | wc -w\n')" \
    "       2"

check_script "exec capture assign" \
    "$(printf 'x = $(echo hello)\necho $x\n')" \
    "hello"

check_script "exec && true" \
    "$(printf 'true && echo yes\n')" \
    "yes"

check_script "exec && false" \
    "$(printf 'false && echo yes\n')" \
    ""

check_script "exec || false" \
    "$(printf 'false || echo fallback\n')" \
    "fallback"

check_script "exec subshell" \
    "$(printf '(echo inside)\n')" \
    "inside"

check_script "exec herestring" \
    "$(printf 'cat <<< \"hello\"\n')" \
    "hello"

check_script "exec test -f true" \
    "$(printf 'if test -f build.zig { echo found }\n')" \
    "found"

check_script "exec test -d true" \
    "$(printf 'if test -d src { echo isdir }\n')" \
    "isdir"

check_script "exec test -f false" \
    "$(printf 'if test -f nonexistent { echo y } else { echo n }\n')" \
    "n"

# Cleanup redirect test file
rm -f /tmp/_slash_redir_test.txt

# ==========================================================================
# EXECUTION: ENVIRONMENT & VARIABLES
# ==========================================================================

check_script "exec echo USER" \
    "$(printf 'echo $USER\n')" \
    "$USER"

check_script "exec echo HOME" \
    "$(printf 'echo $HOME\n')" \
    "$HOME"

check_script "exec herestring var" \
    "$(printf 'cat <<< $HOME\n')" \
    "$HOME"

check_script "exec braced default" \
    "$(printf 'echo ${__SLASH_MISSING__ ?? "."}\n')" \
    "."

check_script "exec uppercase export" \
    "$(printf 'FOO = \"bar\"\n/usr/bin/printenv FOO\n')" \
    "bar"

check_script "exec lowercase not exported" \
    "$(printf 'name = \"bar\"\n/usr/bin/printenv name\n')" \
    ""

check_script "exec nested capture" \
    "$(printf 'echo $(echo $(echo deep))\n')" \
    "deep"

# ==========================================================================
# EXECUTION: FLOAT MATH
# ==========================================================================

check_script "exec float add int" \
    "$(printf '= 1.5 + 2.5\n')" \
    "4"

check_script "exec float div" \
    "$(printf '= 22 / 7\n')" \
    "3.1428571429"

check_script "exec float precision" \
    "$(printf '= 1 / 3\n')" \
    "0.3333333333"

check_script "exec double neg" \
    "$(printf '= -(-3)\n')" \
    "3"

check_script "exec modulo" \
    "$(printf '= 10 %% 3\n')" \
    "1"

# ==========================================================================
# EXECUTION: NO-SPACE MATH
# ==========================================================================

# No-space math uses retryMathSpaced which only works in -c/REPL mode
check "exec nospace power"      "=2**8"       "(display (pow 2 8))"          "256"
check "exec nospace div"        "=22/7"       ""                             "3.1428571429"
check "exec nospace complex"    "=(1+2)*(3+4)" ""                            "21"
check "exec nospace caret"      "=2^10"       ""                             "1024"

# ==========================================================================
# EXECUTION: REDIRECTIONS (advanced)
# ==========================================================================

check_script "exec redirect append" \
    "$(printf 'echo line1 > /tmp/_sl_app.txt\necho line2 >> /tmp/_sl_app.txt\ncat /tmp/_sl_app.txt\n')" \
    "$(printf 'line1\nline2')"

check_script "exec redirect stderr" \
    "$(printf 'echo hello 2> /tmp/_sl_err.txt\necho ok\n')" \
    "$(printf 'hello\nok')"

check_script "exec redirect both" \
    "$(printf 'echo hello &> /tmp/_sl_both.txt\ncat /tmp/_sl_both.txt\n')" \
    "hello"

check_script "exec redirect fd out" \
    "$(printf "python3 -c 'import os; os.write(3, b\"hello\\\\n\")' 3> /tmp/_sl_fd3.txt\ncat /tmp/_sl_fd3.txt\n")" \
    "hello"

rm -f /tmp/_sl_app.txt /tmp/_sl_err.txt /tmp/_sl_both.txt /tmp/_sl_fd3.txt

# ==========================================================================
# EXECUTION: SUBSHELL ISOLATION
# ==========================================================================

check_script "exec subshell cwd" \
    "$(printf '(cd /tmp)\npwd\n')" \
    "$(pwd)"

check_script "exec cd dash" \
    "$(printf 'cd /tmp\ncd -\npwd\n')" \
    "$(pwd)"

# ==========================================================================
# EXECUTION: BOOLEAN SHORT-CIRCUIT
# ==========================================================================

check_script "exec true && echo" \
    "$(printf 'true && echo yes\n')" \
    "yes"

check_script "exec false && echo" \
    "$(printf 'false && echo yes\n')" \
    ""

check_script "exec true || echo" \
    "$(printf 'true || echo no\n')" \
    ""

check_script "exec false || echo" \
    "$(printf 'false || echo fallback\n')" \
    "fallback"

# ==========================================================================
# EXECUTION: USER COMMANDS
# ==========================================================================

check_script "exec cmd define + run" \
    "$(printf 'cmd g echo hello\ng\n')" \
    "hello"

# ==========================================================================
# EXECUTION: BOOLEAN CONDITIONS
# ==========================================================================

check_script "exec test and test" \
    "$(printf 'if test -d /tmp and test -f build.zig { echo both }\n')" \
    "both"

# ==========================================================================
# EXECUTION: FOR LOOP (multi-item)
# ==========================================================================

check_script "exec for 5 items" \
    "$(printf 'for x in a b c d e { echo $x }\n')" \
    "$(printf 'a\nb\nc\nd\ne')"

# ==========================================================================
# EXECUTION: HEREDOC EDGE CASES
# ==========================================================================

check_script "heredoc empty body" \
    "$(printf "cat '''\n    '''\n")" \
    ""

check_script "heredoc lang tag" \
    "$(printf 'cat ```sql\n    SELECT 1\n    ```\n')" \
    "SELECT 1"

# ==========================================================================
# EXECUTION: PROCESS SUBSTITUTION WITH PIPELINE
# ==========================================================================

check_script "exec procsub pipeline" \
    "$(printf 'cat <(echo hello | tr h H)\n')" \
    "Hello"

# ==========================================================================
# EXECUTION: TEST BUILTIN (extended)
# ==========================================================================

check_script "exec test -r" \
    "$(printf 'if test -r build.zig { echo readable }\n')" \
    "readable"

check_script "exec test -w" \
    "$(printf 'if test -w build.zig { echo writable }\n')" \
    "writable"

check_script "exec test -x dir" \
    "$(printf 'if test -x src { echo executable }\n')" \
    "executable"

check_script "exec test -L" \
    "$(printf 'echo hi > /tmp/_sl_target.txt\nln -sf /tmp/_sl_target.txt /tmp/_sl_link.txt\nif test -L /tmp/_sl_link.txt { echo symlink }\nrm -f /tmp/_sl_target.txt /tmp/_sl_link.txt\n')" \
    "symlink"

check_script "exec test unknown flag" \
    "$(printf 'if test -z foo { echo bad } else { echo ok }\n')" \
    "ok"

# ==========================================================================
# EXECUTION: INDENTED CONTROL STRUCTURES
# ==========================================================================

check_script "exec indent for" \
    "$(printf 'for x in a b c\n    echo $x\n')" \
    "$(printf 'a\nb\nc')"

check_script "exec indent while" \
    "$(printf 'x = 0\nwhile $x < 3\n    echo $x\n    x = $x + 1\n')" \
    "$(printf '0\n1\n2')"

check_script "exec indent if else false" \
    "$(printf 'if false\n    echo y\nelse\n    echo n\n')" \
    "n"

# ==========================================================================
# EXECUTION: TRY PATTERN MATCHING
# ==========================================================================

check_script "exec try string match" \
    "$(printf 'x = "hello"\ntry $x { "hello" { echo yes } else { echo no } }\n')" \
    "yes"

check_script "exec try regex match" \
    "$(printf 'x = "hello"\ntry $x { ~|^hel| { echo yes } else { echo no } }\n')" \
    "yes"

check_script "exec try else fallthrough" \
    "$(printf 'x = "other"\ntry $x { "hello" { echo h } else { echo fallback } }\n')" \
    "fallback"

# ==========================================================================
# EXECUTION: CMD DEFINE AND INVOKE
# ==========================================================================

check_script "exec cmd with params" \
    "$(printf 'cmd greet(name) echo hello $name\ngreet world\n')" \
    "hello world"

check_script_all "exec cmd list shows one-line definition" \
    "$(printf 'cmd greet(name) echo hello $name\ncmd\n')" \
    "cmd greet(name) echo hello \$name"

check_script_all "exec cmd list shows full multiline definition" \
    "$(printf 'cmd greet(name)\n    echo hello $name\n    echo done\ncmd\n')" \
    "$(printf 'cmd greet(name)\n    echo hello $name\n    echo done')"

check_script "exec cmd with defaults" \
    "$(printf 'cmd serve(port)\n    port = $port ?? 8080\n    echo $port\nserve\n')" \
    "8080"

check_script "exec list builder command" \
    "$(printf 'cmd greet(name)\n    args = [echo hello]\n    args += [$name]\n    run $args\ngreet world\n')" \
    "hello world"

check_script "exec list run with pipe" \
    "$(printf 'args = [echo hello world]\nrun $args | wc -w\n')" \
    "       2"

check_script "exec list run with redirect" \
    "$(printf 'args = [echo hello]\nrun $args > /tmp/_sl_list_redir.txt\ncat /tmp/_sl_list_redir.txt\n')" \
    "hello"

check_script "exec list splat positional" \
    "$(printf 'cmd test_splat\n    args = [echo]\n    args += [$*]\n    run $args\ntest_splat hello world\n')" \
    "hello world"

check_script "exec list multi-if in cmd" \
    "$(printf 'cmd f(name)\n    match = $name\n    args = [find /tmp -maxdepth 0]\n    if $name != "." { args += [-name tmp] }\n    if $name == "." { match = "" }\n    if $match != "" { run $args 2> /dev/null | grep -i $match }\n    if $match == "" { run $args 2> /dev/null }\nf tmp\n')" \
    "/tmp"

check_script "exec cmd locals do not leak" \
    "$(printf 'name = \"outer\"\ncmd setname\n    name = \"inner\"\n    echo $name\nsetname\necho $name\n')" \
    "$(printf 'inner\nouter')"

check_script "exec cmd uppercase export stays local" \
    "$(printf 'FOO = \"outer\"\ncmd show\n    FOO = \"inner\"\n    /usr/bin/printenv FOO\nshow\necho $FOO\n')" \
    "$(printf 'inner\nouter')"

# ==========================================================================
# EXECUTION: COMPARISON OPERATORS
# ==========================================================================

check_script "exec if ==" \
    "$(printf 'x = "hello"\nif $x == "hello" { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec if !=" \
    "$(printf 'x = "hello"\nif $x != "world" { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec if >=" \
    "$(printf 'x = 10\nif $x >= 10 { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec if <=" \
    "$(printf 'x = 5\nif $x <= 5 { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec if =~" \
    "$(printf 'x = "hello.zig"\nif $x =~ /\\.zig$/ { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec if !~" \
    "$(printf 'x = "hello.txt"\nif $x !~ /\\.zig$/ { echo yes } else { echo no }\n')" \
    "yes"

# ==========================================================================
# EXECUTION: LOOP CONTROL
# ==========================================================================

check_script "exec break" \
    "$(printf 'for x in a b c d e\n    if $x == "c" { break }\n    echo $x\n')" \
    "$(printf 'a\nb')"

check_script "exec continue" \
    "$(printf 'for x in a b c d e\n    if $x == "c" { continue }\n    echo $x\n')" \
    "$(printf 'a\nb\nd\ne')"

check_script "exec until" \
    "$(printf 'x = 0\nuntil $x == 3\n    echo $x\n    x = $x + 1\n')" \
    "$(printf '0\n1\n2')"

check_script "exec exit in loop" \
    "$(printf 'for x in a b c\n    if $x == "b" { exit }\n    echo $x\n')" \
    "a"

# ==========================================================================
# EXECUTION: STRING INTERPOLATION
# ==========================================================================

check_script "exec dq interpolation" \
    "$(printf 'name = "world"\necho "hello $name"\n')" \
    "hello world"

check_script "exec escape sequences" \
    "$(printf 'echo "a\\tb"\n')" \
    "$(printf 'a\tb')"

# ==========================================================================
# EXECUTION: SPECIAL VARIABLES
# ==========================================================================

check_script "exec arg count" \
    "$(printf 'echo $#\n')" \
    "0"

check_script "exec positional args" \
    "$(printf 'echo $1 $2\n')" \
    " "

check_script "exec shift" \
    "$(printf 'echo $1\nshift\necho $1\n')" \
    "$(printf '\n')"

check_script_args "exec shift 2" \
    "$(printf 'echo $1 $2 $3\nshift 2\necho $1 $2 $3\n')" \
    "$(printf 'a b c\nc  ')" \
    a b c

check_script_args "exec shift value assignment" \
    "$(printf 'x = shift\necho $x\necho $1\n')" \
    "$(printf 'a\nb')" \
    a b

check_script_args "exec try shift value" \
    "$(printf 'try shift\n    "--foo" { echo foo }\n    else { echo other }\n')" \
    "foo" \
    --foo

check_script "exec test -e" \
    "$(printf 'if test -e build.zig { echo exists }\n')" \
    "exists"

check_script "exec source" \
    "$(printf 'echo "x = 42" > /tmp/_sl_source.slash\nsource /tmp/_sl_source.slash\necho $x\n')" \
    "42"

rm -f /tmp/_sl_source.slash

check_script "exec xor" \
    "$(printf 'cmd a true xor false\na\necho $?\n')" \
    "0"

check_script "exec comment ignored" \
    "$(printf 'echo hello # this is a comment\n')" \
    "hello"

check_script "exec cmd redefine" \
    "$(printf 'cmd foo echo first\ncmd foo echo second\nfoo\n')" \
    "second"

check_script "exec cmd missing hook" \
    "$(printf 'cmd ??? { echo missing }\nno_such_cmd_xyz\n')" \
    "missing"

check_script "exec cmd missing delete" \
    "$(printf 'cmd ??? { echo hook }\ncmd ??? -\nno_such_cmd_xyz\n')" \
    ""

# ==========================================================================
# GLOB AND PATH TESTS
# ==========================================================================

check_script "exec glob bin/*" \
    "$(printf 'echo bin/*\n')" \
    "bin/grammar bin/slash"

# ==========================================================================
# MATH CONTEXT TESTS
# ==========================================================================

check_script "exec math basic" \
    "$(printf '= 2 + 3\n')" \
    "5"

check_script "exec math multiply" \
    "$(printf '= 6 * 7\n')" \
    "42"

check_script "exec math power" \
    "$(printf '= 2 ** 5\n')" \
    "32"

# ==========================================================================
# EXECUTION: TILDE EXPANSION
# ==========================================================================

check_script "exec tilde home" \
    "$(printf 'echo ~\n')" \
    "$HOME"

check_script "exec tilde path" \
    "$(printf 'echo ~/test\n')" \
    "$HOME/test"

check_script "exec tilde in command arg" \
    "$(printf 'test -d ~ && echo yes\n')" \
    "yes"

# ==========================================================================
# EXECUTION: FLAG=VALUE TOKENIZATION
# ==========================================================================

check "flag with value"         "grep --color=always"       "(cmd grep --color=always)"
check "flag with path value"    "app --config=/etc/foo"     "(cmd app --config=/etc/foo)"
check "flag with complex value" "app --output=a,b,c"        "(cmd app --output=a,b,c)"

check_script "exec flag=value in cmd" \
    "$(printf 'echo --color=always\n')" \
    "--color=always"

# ==========================================================================
# EXECUTION: LIST APPEND TO NONEXISTENT
# ==========================================================================

check_script "exec list append creates" \
    "$(printf 'args += [echo hello]\nrun $args\n')" \
    "hello"

# ==========================================================================
# EXECUTION: LIST WITH VARIABLE SPLAT
# ==========================================================================

check_script "exec list splat argv var" \
    "$(printf 'base = [echo hello]\nargs = [world]\nargs += [$base]\necho not-splatted\n')" \
    "not-splatted"

check_script "exec list with interpolated string" \
    "$(printf 'name = \"world\"\nargs = [echo \"hello $name\"]\nrun $args\n')" \
    "hello world"

# ==========================================================================
# EXECUTION: CMD SCOPE ISOLATION
# ==========================================================================

check_script "exec cmd list stays local" \
    "$(printf 'cmd build\n    args = [echo inside]\n    run $args\nbuild\necho $args\n')" \
    "$(printf 'inside\n')"

check_script "exec cmd nested call scope" \
    "$(printf 'cmd inner\n    x = "inner"\n    echo $x\ncmd outer\n    x = "outer"\n    inner\n    echo $x\nouter\n')" \
    "$(printf 'inner\nouter')"

check_script "exec cmd param does not leak" \
    "$(printf 'cmd greet(name)\n    echo hello $name\ngreet world\necho $name\n')" \
    "$(printf 'hello world\n')"

# ==========================================================================
# EXECUTION: OK BUILTIN
# ==========================================================================

check_script "exec ok suppresses output" \
    "$(printf 'if ok ls /tmp { echo yes } else { echo no }\n')" \
    "yes"

check_script "exec ok with failing command" \
    "$(printf 'unless ok ls /nonexistent_xyz { echo missing }\n')" \
    "missing"

check_script "exec ok exit code passthrough" \
    "$(printf 'ok ls /tmp\necho $?\n')" \
    "0"

check_script "exec ok with id" \
    "$(printf 'if ok id -u root { echo found }\n')" \
    "found"

# ==========================================================================
# EXECUTION: $0 SCRIPT PATH
# ==========================================================================

check_script "exec \$0 is full path" \
    "$(printf 'echo $0\n')" \
    "/tmp/_slash_test_$$.slash"

# Cleanup temp files
rm -f /tmp/_sl_list_redir.txt

# ==========================================================================
# RESULTS
# ==========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed ($(( PASS + FAIL )) total)"
if [ "$FAIL" -gt 0 ]; then
    printf "%b" "$ERRORS"
    exit 1
fi
