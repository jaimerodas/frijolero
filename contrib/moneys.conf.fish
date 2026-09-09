# ~/.config/fish/conf.d/moneys.fish
#
# Set MONEYS_REPO (the ledger clone) and MONEYS_FAVA_DIR (a directory where
# `uv run fava` works) in your config.fish. These are the defaults. The
# handler warns at the prompt when a fava
# session ended without a push (a closed window, a failed push).

set -q MONEYS_REPO; or set -g MONEYS_REPO ~/ledger
set -q MONEYS_FAVA_DIR; or set -g MONEYS_FAVA_DIR ~/fava

function _moneys_warn --on-event fish_prompt
    test -e $MONEYS_REPO/.git/MONEYS_DIRTY; or return
    pgrep -qf "fava $MONEYS_REPO/moneys.beancount"; and return
    set_color yellow; echo "moneys: ledger edits are not pushed. Run moneys."; set_color normal
end
