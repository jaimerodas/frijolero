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

// A button that waits on the server (the classifier, S3) says so, and its form takes no second
// click. The back button can bring the page back from the cache as it was left, so it resets there.
document.addEventListener('submit', (event) => {
  const button = event.submitter;
  if (!button?.dataset.busy) return;
  button.dataset.idle = button.textContent;
  button.textContent = button.dataset.busy;
  button.form.inert = true;
});
window.addEventListener('pageshow', () => {
  for (const button of document.querySelectorAll('button[data-idle]')) {
    button.textContent = button.dataset.idle;
    button.form.inert = false;
    delete button.dataset.idle;
  }
});
