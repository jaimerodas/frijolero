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

// Where the account autocomplete may open, tested on the line up to the word. In Beancount:
// the first word of an indented posting line, or the account word(s) after a directive's date
// and a keyword that takes one. In the rules YAML: the value of `account:`, quoted or not.
const BEANCOUNT_SPOT = /^\s+$|^\d{4}-\d{2}-\d{2} (?:open|close|balance|pad) /;
const RULES_SPOT = /\baccount:\s*['"]?$/;
const ACCOUNT_WORD = /[\w:-]/;

// The word under the caret, if the caret sits right after it (not before or inside it) and
// what comes before it on the line matches `spot`.
function wordContext(text, caret, spot) {
  const lineStart = text.lastIndexOf('\n', caret - 1) + 1;
  const lineEnd = text.indexOf('\n', caret);
  const line = text.slice(lineStart, lineEnd === -1 ? text.length : lineEnd);
  const col = caret - lineStart;
  if (ACCOUNT_WORD.test(line[col] || '') || !ACCOUNT_WORD.test(line[col - 1] || '')) return null;
  let start = col;
  while (start > 0 && ACCOUNT_WORD.test(line[start - 1])) start--;
  if (col - start < 2) return null;
  if (!spot.test(line.slice(0, start))) return null;
  return { start: lineStart + start, word: line.slice(start, col) };
}

// The end of the word to replace on accept: from the caret to the first character an account
// cannot hold, so an accept over a half-typed word eats all of it and never a closing quote.
function wordEnd(text, caret) {
  return caret + text.slice(caret).search(/[^\w:-]|$/);
}

// Where character `index` of the textarea sits, relative to the textarea's own box and its
// scroll: {top of the line under it, left}. A hidden copy with the same box, font and wrapping
// holds the text up to `index` and a marker after it.
function caretPoint(textarea, index) {
  const style = getComputedStyle(textarea);
  const copy = document.createElement('div');
  for (const p of ['fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'letterSpacing', 'tabSize', 'whiteSpace', 'overflowWrap', 'wordBreak',
    'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft']) copy.style[p] = style[p];
  Object.assign(copy.style, { position: 'absolute', visibility: 'hidden', boxSizing: 'border-box', width: `${textarea.clientWidth}px`, border: '0' });
  copy.textContent = textarea.value.slice(0, index);
  const mark = copy.appendChild(document.createElement('span'));
  mark.textContent = '\u200b';
  document.body.append(copy);
  // The marker's box is the glyph's; half the leading below it is the line's bottom.
  const leading = (parseFloat(style.lineHeight) - mark.offsetHeight) / 2 || 0;
  const point = {
    top: textarea.clientTop + mark.offsetTop + mark.offsetHeight + leading - textarea.scrollTop,
    left: textarea.clientLeft + mark.offsetLeft - textarea.scrollLeft,
  };
  copy.remove();
  return point;
}

// Case-insensitive: the typed word splits on ':' and each part must be found, in order, in
// a distinct later segment of the account. Greedy, leftmost match per part, no backtracking
// -- fine for the handful of segments a real account name has. Best first: parts that start
// their segments, then fewer segments skipped (`Expenses:Fo` puts Expenses:Food:* before
// Expenses:Galleta:Food), then shorter names.
function matchAccounts(word, accounts) {
  const parts = word.toLowerCase().split(':').filter(Boolean);
  const scored = [];
  accounts.forEach((account) => {
    const segments = account.toLowerCase().split(':');
    let from = 0;
    let mid = 0;
    let skipped = 0;
    for (const part of parts) {
      const at = segments.slice(from).findIndex((s) => s.includes(part));
      if (at === -1) return;
      if (!segments[from + at].startsWith(part)) mid += 1;
      skipped += at;
      from += at + 1;
    }
    scored.push({ account, mid, skipped });
  });
  scored.sort((a, b) => a.mid - b.mid || a.skipped - b.skipped
    || a.account.length - b.account.length || a.account.localeCompare(b.account));
  return scored.slice(0, 8).map((s) => s.account);
}

let autocompleteId = 0;

// The account suggestion list floating over `textarea`, under the word being typed, in the
// textarea's parent, which is its positioning context. It never touches a line's height.
// `accounts` comes from a `script.accounts` next to it; `spot` says where a word is an account;
// `accepted` runs after a pick (the Beancount editor redraws its colored copy).
function accountAutocomplete(textarea, spot, accepted = () => {}) {
  const accounts = JSON.parse(textarea.parentElement.closest('form').querySelector('script.accounts')?.textContent || '[]');
  const id = `ac${autocompleteId++}`;
  const list = document.createElement('ul');
  list.className = 'suggestions';
  list.id = `${id}-list`;
  list.setAttribute('role', 'listbox');
  list.hidden = true;
  textarea.parentElement.append(list);
  textarea.setAttribute('aria-autocomplete', 'list');
  textarea.setAttribute('aria-controls', list.id);
  textarea.setAttribute('aria-expanded', 'false');
  let current = null;
  let selected = 0;

  function position() {
    const point = caretPoint(textarea, current.start);
    list.style.top = `${textarea.offsetTop + point.top}px`;
    list.style.left = `${textarea.offsetLeft + point.left}px`;
  }

  function select(i) {
    selected = i;
    [...list.children].forEach((li, idx) => li.setAttribute('aria-selected', idx === i ? 'true' : 'false'));
    textarea.setAttribute('aria-activedescendant', list.children[i]?.id || '');
  }

  function hide() {
    if (list.hidden) return;
    list.hidden = true;
    current = null;
    textarea.setAttribute('aria-expanded', 'false');
    textarea.removeAttribute('aria-activedescendant');
  }

  function accept(account) {
    const end = wordEnd(textarea.value, textarea.selectionStart);
    textarea.setRangeText(account, current.start, end, 'end');
    accepted();
    hide();
  }

  function show(context, matches) {
    current = { ...context, accounts: matches };
    list.innerHTML = matches.map((account, i) => `<li role="option" id="${id}-${i}">${escape(account)}</li>`).join('');
    [...list.children].forEach((li, i) => li.addEventListener('mousedown', (event) => {
      event.preventDefault();
      accept(matches[i]);
    }));
    list.hidden = false;
    textarea.setAttribute('aria-expanded', 'true');
    select(0);
    position();
  }

  function update() {
    const context = textarea.selectionStart === textarea.selectionEnd
      && wordContext(textarea.value, textarea.selectionStart, spot);
    const matches = context && matchAccounts(context.word, accounts);
    if (!matches || matches.length === 0 || (matches.length === 1 && matches[0].toLowerCase() === context.word.toLowerCase())) return hide();
    show(context, matches);
  }

  // Consumes ArrowDown/ArrowUp/Tab/Escape while the list shows; Enter is left alone; a
  // caller returning false runs its own handling for the key (Tab's two spaces, mainly).
  function handleKey(event) {
    if (list.hidden) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      select((selected + (event.key === 'ArrowDown' ? 1 : list.children.length - 1)) % list.children.length);
      return true;
    }
    if (event.key === 'Tab') {
      event.preventDefault();
      accept(current.accounts[selected]);
      return true;
    }
    if (event.key === 'Escape') {
      event.preventDefault(); // also stops the journal's <dialog> from closing on Escape
      hide();
      return true;
    }
    return false;
  }

  textarea.addEventListener('input', update);
  textarea.addEventListener('blur', hide);
  textarea.addEventListener('click', hide);
  return { handleKey };
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
  let found = [];

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
    // The directive's first line and the indented lines under it, as beancount_html marks them.
    for (let l = line; l && (l === line || /^[ \t]+\S/.test(l.textContent)); l = l.nextElementSibling) {
      l.classList.add('err');
      l.setAttribute('title', `${error.code} ${error.message}`);
    }
    if (line) link.addEventListener('click', () => goTo(error.line));
    return li;
  }

  function showErrors(list) {
    errors.replaceChildren(...list.map(errorItem));
    errors.hidden = list.length === 0;
  }

  // `original` is what the save compares against, so it is the text as the server gave it.
  // `errors` are the ones the ledger already has inside `text`, marked from the start
  // and again after Cancelar.
  function open(text, start = 1, errors = []) {
    first = start;
    found = errors;
    form.elements.original.value = text;
    textarea.value = text;
    render(text);
    form.classList.add('editing');
    textarea.hidden = false;
    actions.hidden = false;
    showErrors(found);
    dialog?.showModal();
    textarea.focus();
  }

  function close() {
    render(form.elements.original.value);
    form.classList.remove('editing');
    textarea.hidden = true;
    actions.hidden = true;
    showErrors(found);
    dialog?.close();
  }

  form.querySelector('button[value="cancel"]').addEventListener('click', close);

  const accounts = accountAutocomplete(textarea, BEANCOUNT_SPOT, () => render(textarea.value));

  textarea.addEventListener('input', () => render(textarea.value));

  // Tab indents two spaces, as a posting needs; ⌘S or Ctrl+S saves. The account list, when
  // it shows, gets first refusal on Tab/Escape/the arrows.
  textarea.addEventListener('keydown', (event) => {
    if (accounts.handleKey(event)) return;
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

const form = document.querySelector('form.code:not(.rules-editor)');
if (form) {
  const ed = editor(form);

  // Statement and file pages: Editar fetches the whole file.
  document.querySelector('button.edit-file')?.addEventListener('click', async () => {
    const response = await fetch(`/edit?${new URLSearchParams({ file: form.elements.file.value })}`).catch(() => null);
    if (!response?.ok) return ed.showErrors([response ? await response.text() : 'Sin conexión']);
    const block = await response.json();
    ed.open(block.text, 1, block.errors);
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
    ed.open(block.text, block.first, block.errors);
    if (!response?.ok) ed.showErrors([response ? await response.text() : 'Sin conexión']);
  });
}

// The rules editor: a plain textarea in the page, which becomes the Beancount editor's layout
// for the line numbers (a numbered pre under a transparent textarea; plain text, no colors),
// with the same list after `account:`. With no list, Tab keeps its native job of moving the focus.
const rules = document.querySelector('form.rules-editor textarea');
if (rules) {
  const surface = document.createElement('div');
  const pre = document.createElement('pre');
  surface.className = 'surface';
  rules.before(surface);
  surface.append(pre, rules);
  rules.form.classList.add('code', 'editing');
  const render = () => {
    pre.innerHTML = rules.value.split('\n').map((line, i) => `<span class="line" id="L${i + 1}">${escape(line)}</span>`).join('');
  };
  render();
  rules.addEventListener('input', render);
  const accounts = accountAutocomplete(rules, RULES_SPOT, render);
  rules.addEventListener('keydown', (event) => accounts.handleKey(event));

  // "Hacer regla" leaves the caret after the new entry's `account: `, with its line in view.
  if (rules.dataset.caret) {
    const at = Number(rules.dataset.caret);
    rules.focus({ preventScroll: true });
    rules.setSelectionRange(at, at);
    pre.children[rules.value.slice(0, at).split('\n').length - 1]?.scrollIntoView({ block: 'center' });
  }
}
