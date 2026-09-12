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

// The journal's edit dialog, opened from the date of an entry. The text of one
// transaction comes from /edit and goes back to it. A save the ledger rejects
// shows the errors and stays open; a saved one reloads the page, which keeps
// the scroll position.
const dialog = document.getElementById('edit');
const form = dialog?.querySelector('form');

function showError(text) {
  const error = form.querySelector('.error');
  error.textContent = text;
  error.hidden = !text;
}

document.addEventListener('click', async (event) => {
  const button = event.target.closest('button.edit');
  if (!button) return;
  const { file, line, statement } = button.dataset;
  const response = await fetch(`/edit?${new URLSearchParams({ file, line })}`).catch(() => null);
  const block = response?.ok ? await response.json() : { text: '' };
  form.elements.file.value = file;
  form.elements.line.value = line;
  form.elements.original.value = block.text;
  form.elements.content.value = block.text;
  const link = form.querySelector('.meta .statement');
  link.textContent = file;
  if (statement) link.href = statement; else link.removeAttribute('href');
  form.querySelector('.meta .lines').textContent = `líneas ${block.first}–${block.last}`;
  showError(response?.ok ? '' : response ? await response.text() : 'Sin conexión');
  dialog.showModal();
});

form?.addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const response = await fetch('/edit', { method: 'POST', body: new FormData(form) }).catch(() => null);
  if (response?.status === 204) return location.reload();
  showError(response ? await response.text() : 'Sin conexión');
});
