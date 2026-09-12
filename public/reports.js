// Fold and unfold the account tree. A parent row's name is a button; opening it
// shows its direct children, closing it hides the whole subtree and resets it.
document.addEventListener('click', (event) => {
  const button = event.target.closest('button.fold');
  if (!button) return;
  const row = button.closest('tr');
  const open = button.getAttribute('aria-expanded') !== 'true';
  const prefix = `${row.dataset.account}:`;
  const childDepth = Number(row.dataset.depth) + 1;
  button.setAttribute('aria-expanded', open);
  for (const other of row.parentElement.querySelectorAll('tr')) {
    if (!other.dataset.account.startsWith(prefix)) continue;
    other.hidden = !open || Number(other.dataset.depth) !== childDepth;
    if (!open) other.querySelector('button.fold')?.setAttribute('aria-expanded', 'false');
  }
});

// The period menu and the journal's chart menu submit their GET form on change:
// choosing an option is the submit.
document.addEventListener('change', (event) => {
  if (event.target.matches('select[name="period"], select[name="chart"]')) event.target.form.requestSubmit();
});
