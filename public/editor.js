// The editor of Beancount text, over a form.code: the whole file on the statement page and
// on /files/<path>, one transaction in the journal's dialog. A transparent textarea lies over
// the colored <pre>: the textarea holds the text and the caret, the pre is redrawn on every
// keystroke and sets the height, so there is no scroll to sync. The two share font, padding
// and wrapping (see .code in style.css).
//
// TOKEN is the JS copy of App::BEANCOUNT_TOKEN in app/statements.rb: keep the two identical.
const TOKEN = /(?<head>^\d{4}-\d{2}-\d{2} \S+)|(?<comment>(?<!\S);.*)|(?<string>&quot;.*?&quot;)|(?<account>(?:Assets|Liabilities|Equity|Income|Expenses)(?::[\w-]+)+)|(?<amount>-?\d[\d,]*(?:\.\d+)? [A-Z][A-Z0-9._-]*)/g;

const escape = (text) => text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

// Same classes as beancount_span and beancount_head in app/statements.rb.
function span(kind, text) {
  if (kind === 'string') return text;
  if (kind === 'head') {
    const [date, flag] = text.split(' ');
    return `<span class="bc-date">${date}</span> <span class="bc-flag${flag === '!' ? ' bc-warn' : ''}">${flag}</span>`;
  }
  const klass = kind === 'account' ? (text.startsWith('Expenses:FIXME') ? 'bc-account bc-fixme' : 'bc-account')
    : kind === 'amount' ? (text.startsWith('-') ? 'debit' : 'credit')
      : `bc-${kind}`;
  return `<span class="${klass}">${text}</span>`;
}

function highlight(line) {
  return escape(line).replace(TOKEN, (match, ...rest) => {
    const groups = rest.at(-1);
    return span(Object.keys(groups).find((k) => groups[k] !== undefined), match);
  });
}

// Wires one form.code. `open(text, first)` puts `text` in the editor, numbered from file
// line `first`, so an error's line maps to the same `#L<n>` on a whole file and on a block.
function editor(form) {
  const pre = form.querySelector('pre');
  const textarea = form.elements.content;
  const errors = form.querySelector('.errors');
  const actions = form.querySelector('.actions');
  const dialog = form.closest('dialog');
  let first = 1;

  function render(text) {
    pre.style.counterReset = `line ${first - 1}`;
    pre.innerHTML = text.split('\n').map((line, i) => `<span class="line" id="L${first + i}">${highlight(line)}</span>`).join('');
  }

  // Puts the caret at the start of file line n.
  function goTo(n) {
    const offset = textarea.value.split('\n').slice(0, n - first).reduce((sum, line) => sum + line.length + 1, 0);
    textarea.focus({ preventScroll: true });
    textarea.setSelectionRange(offset, offset);
  }

  // An error on a line in view marks it and links to it; any other links to that file's
  // own editor page, where :target marks the line. A string is shown as is.
  function errorItem(error) {
    const li = document.createElement('li');
    if (typeof error === 'string') {
      li.textContent = error;
      return li;
    }
    const line = error.file === form.elements.file.value && pre.querySelector(`#L${error.line}`);
    const link = document.createElement('a');
    link.href = line ? `#L${error.line}` : `/files/${encodeURI(error.file)}#L${error.line}`;
    link.textContent = `${error.file}:${error.line}`;
    li.append(`${error.code} ${error.message} `, link);
    if (line) {
      line.classList.add('err');
      line.setAttribute('title', `${error.code} ${error.message}`);
      link.addEventListener('click', () => goTo(error.line));
    }
    return li;
  }

  function showErrors(list) {
    errors.replaceChildren(...list.map(errorItem));
    errors.hidden = list.length === 0;
  }

  // `original` is what the save compares against, so it is the text as the server gave it.
  function open(text, start = 1) {
    first = start;
    form.elements.original.value = text;
    textarea.value = text;
    render(text);
    form.classList.add('editing');
    textarea.hidden = false;
    actions.hidden = false;
    showErrors([]);
    dialog?.showModal();
    textarea.focus();
  }

  function close() {
    render(form.elements.original.value);
    form.classList.remove('editing');
    textarea.hidden = true;
    actions.hidden = true;
    showErrors([]);
    dialog?.close();
  }

  form.querySelector('button[value="cancel"]').addEventListener('click', close);

  textarea.addEventListener('input', () => render(textarea.value));

  // Tab indents two spaces, as a posting needs; ⌘S or Ctrl+S saves.
  textarea.addEventListener('keydown', (event) => {
    if (event.key === 'Tab') {
      event.preventDefault();
      textarea.setRangeText('  ', textarea.selectionStart, textarea.selectionEnd, 'end');
      render(textarea.value);
    } else if (event.key === 's' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  // A clean save reloads: the dialog in place, which keeps the scroll position; a page on
  // its Beancount view. A rejected one lists the errors and stays.
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const response = await fetch('/edit', { method: 'POST', body: new FormData(form) }).catch(() => null);
    if (response?.status === 204) return dialog ? location.reload() : location.replace(`${location.pathname}?saved=1`);
    if (response?.status === 422) return showErrors((await response.json()).errors);
    showErrors([response ? await response.text() : 'Sin conexión']);
  });

  return { open, showErrors };
}

const form = document.querySelector('form.code');
if (form) {
  const ed = editor(form);

  // Statement and file pages: Editar fetches the whole file.
  document.querySelector('button.edit-file')?.addEventListener('click', async () => {
    const response = await fetch(`/edit?${new URLSearchParams({ file: form.elements.file.value })}`).catch(() => null);
    if (!response?.ok) return ed.showErrors([response ? await response.text() : 'Sin conexión']);
    ed.open((await response.json()).text);
  });

  // The journal: the date of an entry opens the dialog with that one transaction.
  document.addEventListener('click', async (event) => {
    const button = event.target.closest('button.edit');
    if (!button) return;
    const { file, line, statement } = button.dataset;
    const response = await fetch(`/edit?${new URLSearchParams({ file, line })}`).catch(() => null);
    const block = response?.ok ? await response.json() : { text: '', first: 1 };
    form.elements.file.value = file;
    form.elements.line.value = line;
    const link = form.closest('dialog').querySelector('.statement');
    link.textContent = file;
    if (statement) link.href = statement; else link.removeAttribute('href');
    ed.open(block.text, block.first);
    if (!response?.ok) ed.showErrors([response ? await response.text() : 'Sin conexión']);
  });
}
