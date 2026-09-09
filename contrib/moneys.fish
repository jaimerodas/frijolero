# ~/.config/fish/functions/moneys.fish
# Start: commit any leftover edits, pull with rebase, push if anything is
# waiting. Then run fava. Stop (Ctrl-C): commit and push; if the remote moved
# during the session (the droplet added a statement, or you saved rules in
# the web app), pull once more and push again. The sh wrapper catches the
# interrupt and exits with 0, so fish does not cancel the function.

function moneys --description 'Pull the ledger, run fava, push your edits'
    set -l repo $MONEYS_REPO
    _moneys_commit $repo; and echo "moneys: committed edits left over from the last session"
    _moneys_sync $repo
    touch $repo/.git/MONEYS_DIRTY
    sh -c 'trap "exit 0" INT; cd "$1" && uv run fava "$2"' _ $MONEYS_FAVA_DIR $repo/moneys.beancount
    _moneys_commit $repo
    if _moneys_sync $repo
        rm -f $repo/.git/MONEYS_DIRTY
    else
        echo "moneys: push failed. Edits are committed locally. Run moneys again to push." >&2
    end
end

function _moneys_commit --argument-names repo
    git -C $repo add -A
    git -C $repo diff --cached --quiet; and return 1
    git -C $repo commit -qm "Edits from fava "(date +%Y-%m-%d)
end

# Pull with rebase, then push whatever is ahead of the remote. Returns 1 only
# when a push was needed and failed.
function _moneys_sync --argument-names repo
    git -C $repo pull --rebase -q; or echo "moneys: pull failed, working offline" >&2
    test (git -C $repo rev-list --count @{u}..HEAD 2>/dev/null; or echo 0) -gt 0; or return 0
    git -C $repo push -q
end
