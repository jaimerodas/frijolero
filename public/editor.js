// The editor of Beancount text, over a form.code: the whole file on the statement page and
// on /files/<path>, one transaction in the journal's dialog. A transparent textarea lies over
// the colored <pre>: the textarea holds the text and the caret, the pre is redrawn on every
// keystroke and sets the height, so there is no scroll to sync. The two share font, padding
// and wrapping (see .code in style.css).
//
// TOKEN is the JS copy of App::BEANCOUNT_TOKEN in app/statements.rb: keep the two identical.
const TOKEN = /(?<head>^\d{4}-\d{2}-\d{2} \S+)|(?<comment>(?<!\S);.*)|(?<string>&quot;.*?&quot;)|(?<account>(?:Assets|Liabilities|Equity|Income|Expenses)(?::[\w-]+)+)|(?<amount>-?\d[\d,]*(?:\.\d+)? [A-Z][A-Z0-9._-]*)/g;

// The rules YAML in the same colors, on the escaped line: a section or a pattern (the entry's
// head, unquoted or quoted) in ink at 600 like the flag, `# comments` and the field names muted
// like dates, an account in blue, an `amount:` by its sign. Payee and narration stay plain,
// as the quoted payee and narration of a transaction do.
const RULES_TOKEN = /(?<pattern>^(?:start_with|include)(?=:)|(?<=^ {2})(?:&quot;.*?&quot;|&#39;.*?&#39;|[^\s&#-].*?)(?=:(?: |$)))|(?<comment>(?<!\S)#.*)|(?<key>\b(?:payee|narration|account|when|amount)(?=:))|(?<account>(?:Assets|Liabilities|Equity|Income|Expenses)(?::[\w-]+)+)|(?<amount>(?<=\bamount:\s*)-?\d[\d,]*(?:\.\d+)?)/g;

// accounts.yaml the same way: an account's key (column 0, the entry's head) in ink at 600 like a
// rules pattern, its field names and `# comments` muted, accounts in blue. A Multi's printed
// names, one level deeper under `accounts:`, stay plain.
const ACCOUNTS_TOKEN = /(?<pattern>^[^\s#-].*?(?=:(?: |$)))|(?<comment>(?<!\S)#.*)|(?<key>(?<=^ {2})\w+(?=:))|(?<account>(?:Assets|Liabilities|Equity|Income|Expenses)(?::[\w-]+)+)/g;

// The ledger's prefix (/l/<id>), which every App route the editor calls or links to needs.
const ROOT = document.querySelector('meta[name="ledger-root"]').content;

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

function highlight(line, token = TOKEN) {
  return escape(line).replace(token, (match, ...rest) => {
    const groups = rest.at(-1);
    return span(Object.keys(groups).find((k) => groups[k] !== undefined), match);
  });
}

// Where the account autocomplete may open, tested on the line up to the word. In Beancount:
// the first word of an indented posting line, or the account word(s) after a directive's date
// and a keyword that takes one. In the rules YAML: the value of `account:`, quoted or not. In
// accounts.yaml: the value of `beancount_account:` or any `<name>_account:`, or of a Multi's
// printed name (the `accounts:` map is the only thing four spaces deep).
const BEANCOUNT_SPOT = /^\s+$|^\d{4}-\d{2}-\d{2} (?:open|close|balance|pad) /;
const RULES_SPOT = /\baccount:\s*['"]?$/;
const ACCOUNTS_SPOT = /(?:_account|^ {4}[^\s#][^#]*):\s*['"]?$/;
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
// `textarea` can also be an <input> (the edit dialog's Campos): the list then opens under it.
// `accounts` comes from a `script.accounts` in its form, or else in the page; `spot` says where
// a word is an account; `accepted` runs after a pick (the Beancount editor redraws its colored copy).
function accountAutocomplete(textarea, spot, accepted = () => {}) {
  const field = textarea.tagName === 'INPUT';
  const source = textarea.form?.querySelector('script.accounts') ?? document.querySelector('script.accounts');
  const accounts = JSON.parse(source?.textContent || '[]');
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
    const point = field ? { top: textarea.offsetHeight, left: 0 } : caretPoint(textarea, current.start);
    list.style.top = `${textarea.offsetTop + point.top}px`;
    list.style.left = `${textarea.offsetLeft + point.left}px`;
    if (!field) return;
    // As wide as the field, and above it when the dialog, which clips it, has no room below.
    list.style.width = `${textarea.offsetWidth}px`;
    const bottom = textarea.closest('dialog')?.getBoundingClientRect().bottom ?? Infinity;
    if (textarea.getBoundingClientRect().bottom + list.offsetHeight > bottom) list.style.top = `${textarea.offsetTop - list.offsetHeight}px`;
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

  // Consumes ArrowDown/ArrowUp/Tab/Escape while the list shows, and Enter in an <input>, where it
  // would save; in a textarea Enter breaks the line. A caller returning false runs its own
  // handling for the key (Tab's two spaces, mainly).
  function handleKey(event) {
    if (list.hidden) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      select((selected + (event.key === 'ArrowDown' ? 1 : list.children.length - 1)) % list.children.length);
      return true;
    }
    if (event.key === 'Tab' || (field && event.key === 'Enter')) {
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

// A textarea laid over a numbered pre, the layout of every editor here: the pre is redrawn
// from the textarea with `paint` on each line, numbered from `first`, the gutter as wide as the
// last number (`--digits`, three at least); the line under the caret
// gets `.current` while the textarea has the focus; and the account list opens where `spot`
// says. Returns `draw(text, first)` and the list's key handler, which a keydown asks first.
function codeSurface(textarea, pre, paint, spot) {
  let first = 1;
  function mark() {
    pre.querySelector('.line.current')?.classList.remove('current');
    if (document.activeElement !== textarea) return;
    pre.children[textarea.value.slice(0, textarea.selectionStart).split('\n').length - 1]?.classList.add('current');
  }
  function draw(text = textarea.value, start = first) {
    first = start;
    const lines = text.split('\n');
    pre.parentElement.style.setProperty('--digits', Math.max(3, String(first + lines.length - 1).length));
    pre.style.counterReset = `line ${first - 1}`;
    pre.innerHTML = lines.map((line, i) => `<span class="line" id="L${first + i}">${paint(line)}</span>`).join('');
    mark();
  }
  textarea.addEventListener('input', () => draw());
  for (const type of ['keyup', 'click', 'focus', 'blur']) textarea.addEventListener(type, mark);
  return { draw, mark, handleKey: accountAutocomplete(textarea, spot, () => draw()).handleKey };
}

// Posts an edit form to /edit: true on a clean save, else false, with the errors shown through
// `show`: the check's when it refused the edit (422), or the server's one line.
async function postEdit(form, show) {
  const response = await fetch(`${ROOT}/edit`, { method: 'POST', body: new FormData(form) }).catch(() => null);
  if (response?.status === 204) return true;
  show(response?.status === 422 ? (await response.json()).errors : [response ? await response.text() : 'Sin conexión']);
  return false;
}

// Wires one form.code. `open(text, first)` puts `text` in the editor, numbered from file
// line `first`, so an error's line maps to the same `#L<n>` on a whole file and on a block.
function editor(form) {
  const pre = form.querySelector('pre');
  const textarea = form.elements.content;
  const errors = form.querySelector('.errors');
  const actions = form.querySelector('.actions');
  const dialog = form.closest('dialog');
  const surface = codeSurface(textarea, pre, highlight, BEANCOUNT_SPOT);
  let first = 1;
  let found = [];

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
    link.href = line ? `#L${error.line}` : `${ROOT}/files/${encodeURI(error.file)}#L${error.line}`;
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
    surface.draw(text, first);
    form.classList.add('editing');
    textarea.hidden = false;
    actions.hidden = false;
    showErrors(found);
    if (dialog && !dialog.open) dialog.showModal();
    // The caret at the top, focused where the page already is: not a jump to the file's end.
    textarea.setSelectionRange(0, 0);
    textarea.focus({ preventScroll: true });
  }

  // Blurred first, so the redraw marks no current line in read mode.
  function close() {
    textarea.blur();
    surface.draw(form.elements.original.value);
    form.classList.remove('editing');
    textarea.hidden = true;
    actions.hidden = true;
    showErrors(found);
    dialog?.close();
  }

  // On a page of its own (a statement's /beancount/edit), Cancelar goes back to the page to read.
  const back = form.dataset.back;
  form.querySelector('button[value="cancel"]').addEventListener('click', () => (back ? location.assign(back) : close()));

  // Tab indents two spaces, as a posting needs; ⌘S or Ctrl+S saves. The account list, when
  // it shows, gets first refusal on Tab/Escape/the arrows.
  textarea.addEventListener('keydown', (event) => {
    if (surface.handleKey(event)) return;
    if (event.key === 'Tab') {
      event.preventDefault();
      textarea.setRangeText('  ', textarea.selectionStart, textarea.selectionEnd, 'end');
      surface.draw();
    } else if (event.key === 's' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  // A clean save reloads: the dialog in place, which keeps the scroll position; a page, or
  // the page it came from, with its notice. A rejected one lists the errors and stays.
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!await postEdit(form, showErrors)) return;
    if (dialog) location.reload(); else location.replace(`${back || location.pathname}?saved=1`);
  });

  return { open, showErrors };
}

const form = document.querySelector('form.code:not([data-yaml])');
if (form) {
  const ed = editor(form);

  // The file page's Editar, and a statement's /beancount/edit on load: fetch the whole file.
  const openFile = async () => {
    const response = await fetch(`${ROOT}/edit?${new URLSearchParams({ file: form.elements.file.value })}`).catch(() => null);
    if (!response?.ok) return ed.showErrors([response ? await response.text() : 'Sin conexión']);
    const block = await response.json();
    ed.open(block.text, 1, block.errors);
  };
  document.querySelector('button.edit-file')?.addEventListener('click', openFile);
  if (form.dataset.back) openFile();

  const dialog = form.closest('dialog');
  if (dialog) editDialog(dialog, ed);
}

// The dialog's Campos: the payee, the narration and the account of each posting, from GET /edit's
// `fields`. The save sends them without `content`, and the server writes the text, so the narration
// that it replaces stays in source_desc, as with the rules. `open(block)` fills it and focuses the
// account to classify, its text selected, so typing replaces it: Enter picks a suggestion, then saves.
function fieldsForm(form) {
  const dialog = form.closest('dialog');
  const row = form.querySelector('.ledger li');
  const postings = form.querySelector('.postings');
  const hint = form.querySelector('.hint');
  const errors = form.querySelector('.errors');
  const { payee, narration } = form.elements;
  let kept = false;
  let busy = false;

  const element = (tag, props) => Object.assign(document.createElement(tag), props);

  function showErrors(list) {
    errors.replaceChildren(...list.map((e) => element('li', { textContent: typeof e === 'string' ? e : `${e.code} ${e.message}` })));
    errors.hidden = list.length === 0;
  }

  // One posting: its account, with the list where it can be any open account, and the rest of
  // its line (the amount, a cost, a price) as it is in the text.
  function posting({ index, account, rest }, n) {
    const line = element('div', { className: 'posting' });
    const input = element('input', { name: `account[${index}]`, value: account, className: 'account', autocomplete: 'off', spellcheck: false });
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('aria-label', rest ? `Cuenta ${n + 1}, ${rest}` : `Cuenta ${n + 1}`);
    line.append(input, element('data', { textContent: rest, className: rest.startsWith('-') ? 'debit' : 'credit' }));
    const { handleKey } = accountAutocomplete(input, /^\s*$/);
    input.addEventListener('keydown', handleKey);
    return line;
  }

  function open(block) {
    const { fields } = block;
    form.elements.original.value = block.text;
    const [merchant, tail] = fields.description;
    row.querySelector('time').textContent = block.text.slice(0, 10);
    const first = element('div', { textContent: merchant });
    if (fields.flag === '!') first.append(' ', element('span', { className: 'flag', textContent: '!' }));
    row.querySelector('.entry').replaceChildren(first, ...(tail ? [element('div', { className: 'tail', textContent: tail })] : []));
    payee.value = fields.payee;
    narration.value = narration.defaultValue = fields.narration;
    kept = fields.source_desc;
    hint.hidden = true;
    postings.replaceChildren(...fields.postings.map(posting));
    showErrors(block.errors || []);
    if (!dialog.open) dialog.showModal();
    const accounts = [...postings.querySelectorAll('input')];
    const target = accounts.find((input) => input.value === 'Expenses:FIXME') ?? accounts.at(-1) ?? payee;
    target.focus();
    target.select();
  }

  narration.addEventListener('input', () => { hint.hidden = kept || narration.value === narration.defaultValue; });
  form.querySelector('button[value="cancel"]').addEventListener('click', () => dialog.close());

  // Enter in any field saves, as in any one form. A second Enter while the first save runs
  // would post a stale original: 409.
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    busy = true;
    if (await postEdit(form, showErrors)) return location.reload();
    busy = false;
  });

  return { form, open };
}

// The dialog of one transaction, which the date of an entry opens: Campos when the server can read
// the transaction's fields, else the text alone, with no tabs. A tab is filled from the server's block
// each time it shows, so the tab that the person leaves resets.
function editDialog(dialog, ed) {
  const code = dialog.querySelector('form.code');
  const fields = fieldsForm(dialog.querySelector('form.fields'));
  const tabs = dialog.querySelector('.tabs');
  let block;

  function show(tab) {
    for (const button of tabs.children) button.setAttribute('aria-pressed', button.dataset.tab === tab);
    fields.form.hidden = tab !== 'fields';
    code.hidden = tab !== 'code';
    if (tab === 'fields') fields.open(block); else ed.open(block.text, block.first, block.errors);
  }

  tabs.addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (button && button.getAttribute('aria-pressed') !== 'true') show(button.dataset.tab);
  });

  document.addEventListener('click', async (event) => {
    const button = event.target.closest('button.edit');
    if (!button) return;
    const { file, line, statement } = button.dataset;
    const response = await fetch(`${ROOT}/edit?${new URLSearchParams({ file, line })}`).catch(() => null);
    block = response?.ok ? await response.json() : { text: '', first: 1 };
    for (const form of [code, fields.form]) {
      form.elements.file.value = file;
      form.elements.line.value = line;
    }
    const link = dialog.querySelector('.statement');
    link.textContent = file;
    if (statement) link.href = statement; else link.removeAttribute('href');
    tabs.hidden = !block.fields;
    show(block.fields ? 'fields' : 'code');
    if (!response?.ok) ed.showErrors([response ? await response.text() : 'Sin conexión']);
  });
}

// The YAML editors (an account's rules, its block of accounts.yaml, the whole file): a plain
// textarea in the page, which becomes the Beancount editor's layout for the line numbers (a
// numbered pre under a transparent textarea), in the same colors, with the same list where an
// account goes. `data-yaml` picks the grammar. With no list, Tab keeps its native job of moving the focus.
const YAML = { rules: [RULES_TOKEN, RULES_SPOT], accounts: [ACCOUNTS_TOKEN, ACCOUNTS_SPOT] };
const yaml = document.querySelector('form[data-yaml] textarea');
if (yaml) {
  const [token, spot] = YAML[yaml.form.dataset.yaml];
  const box = document.createElement('div');
  const pre = document.createElement('pre');
  box.className = 'surface';
  yaml.before(box);
  box.append(pre, yaml);
  yaml.form.classList.add('code', 'editing');
  const surface = codeSurface(yaml, pre, (line) => highlight(line, token), spot);
  surface.draw();
  yaml.addEventListener('keydown', (event) => surface.handleKey(event));

  // "Hacer regla" leaves the caret after the new entry's `account: `, with its line in view.
  if (yaml.dataset.caret) {
    const at = Number(yaml.dataset.caret);
    yaml.focus({ preventScroll: true });
    yaml.setSelectionRange(at, at);
    surface.mark();
    pre.children[yaml.value.slice(0, at).split('\n').length - 1]?.scrollIntoView({ block: 'center' });
  }
}
