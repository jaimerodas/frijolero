// The chart block of the journal and of the two reports. Ruby embeds the
// chart's name and its rows in #chart-data: for the journal, the period and the
// matched postings (date, currency, amount in the report sign, account, payee);
// for the Sankey, the period as a param and the leaves of Income and Expenses;
// for the icicle, the period as a param and the Assets accounts. d3 does the
// rest. Dates are plain days: utcParse and the utc intervals keep them as written.
const block = document.getElementById('chart-data');
const data = JSON.parse(block.textContent);
const section = block.parentElement;
const query = new URLSearchParams(location.search);
let width;
const height = 200;
const parse = d3.utcParse('%Y-%m-%d');
const from = parse(data.period.from);
const to = parse(data.period.to);
const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const QUARTER = d3.utcMonth.every(3);
const year = (d) => d.getUTCFullYear();
const month = (d) => MESES[d.getUTCMonth()];
const quarter = (d) => Math.floor(d.getUTCMonth() / 3) + 1;

// A link to this page with part of the query changed, so the chart stays open.
function link(changes) {
  const next = new URLSearchParams(query);
  for (const [key, value] of Object.entries(changes)) next.set(key, value);
  return `/journal?${next}`;
}

const amount = new Intl.NumberFormat('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const money = (value, currency) => `${amount.format(value)} ${currency}`;
// The amount axis: the full number under a thousand, then K and M.
const short = (v) => (Math.abs(v) < 1000 ? d3.format(',')(v) : d3.format('.3~s')(v).replace('k', 'K'));
const currencies = [...new Set((data.postings ?? []).map((p) => p.currency))];
const tip = d3.select(section).append('div').attr('class', 'tip').attr('hidden', true);
tip.append('span').attr('class', 'when');
tip.append('data');
tip.append('span').attr('class', 'count');
tip.append('span').attr('class', 'mean');

// The tip is kept inside the block: one that overhung an edge widened the page,
// and the scrollbar shifted the whole view.
// Two more lines when there is a count: the postings behind the figure, and their mean as µ.
function showTip(event, when, value, currency, count) {
  const [px, py] = d3.pointer(event, section);
  tip.select('.when').text(when);
  tip.select('data').attr('value', value).text(money(value, currency));
  tip.select('.count').text(count == null ? '' : `${count} movimiento${count === 1 ? '' : 's'}`);
  tip.select('.mean').text(count > 1 ? `µ ${money(value / count, currency)}` : '');
  tip.attr('hidden', null);
  const half = tip.node().offsetWidth / 2;
  tip.style('left', `${Math.min(Math.max(px, half), section.clientWidth - half)}px`).style('top', `${py}px`);
}
const hideTip = () => tip.attr('hidden', true);

// Four steps of tone by the square root of a share, like a grey scale; style.css
// sets the colour of each step and of its label.
const step = (share) => { const r = Math.sqrt(share); return r >= 0.75 ? 1 : r >= 0.5 ? 2 : r >= 0.25 ? 3 : 4; };
// The height of a chart that fills the viewport under its own top.
const fill = () => Math.max(320, window.innerHeight - section.getBoundingClientRect().top - window.scrollY - 40);

function figure(currency, h = height) {
  const fig = d3.select(section).append('figure');
  if (currencies.length > 1) fig.append('figcaption').text(currency);
  return fig.append('svg').attr('viewBox', [0, 0, width, h]);
}

// Histogram. Finest first; a bucket is offered only when it is finer than the
// page's resolution. `param` is the bucket as a ?period=, so its bar links to
// the same journal over it.
const BUCKETS = {
  day: { label: 'Día', interval: d3.utcDay, format: (d) => `${d.getUTCDate()} ${month(d)} ${year(d)}` },
  month: { label: 'Mes', interval: d3.utcMonth, format: (d) => `${month(d)} ${year(d)}`,
    param: (d) => `${year(d)}-${String(d.getUTCMonth() + 1).padStart(2, '0')}` },
  quarter: { label: 'Trimestre', interval: QUARTER, format: (d) => `T${quarter(d)} ${year(d)}`,
    param: (d) => `${year(d)}-T${quarter(d)}` },
  year: { label: 'Año', interval: d3.utcYear, format: (d) => `${year(d)}`, param: (d) => `${year(d)}` },
};
const FINER = { month: ['day'], quarter: ['day', 'month'], year: ['day', 'month', 'quarter'], all: Object.keys(BUCKETS) };
const DEFAULT = { month: 'day', quarter: 'month', year: 'month', all: 'year' };

// The x axis. Over months, quarters or years, every nth bar with its own label.
// Over days, the starts of a calendar interval: months, quarters or years, the
// finest that gives at least two marks and at most one per 80 px, with January
// written as the year, like d3's own time axis. A single month, every nth day.
const CALENDAR = [d3.utcMonth, QUARTER, d3.utcYear];
function ticks(starts, bucket, slots) {
  const nth = d3.range(0, starts.length, Math.ceil(starts.length / slots));
  if (bucket !== BUCKETS.day) return { at: nth, label: bucket.format };
  for (const interval of CALENDAR) {
    const at = d3.range(starts.length).filter((i) => +interval.floor(starts[i]) === +starts[i]);
    if (at.length >= 2 && at.length <= slots) return { at, label: (d) => (d.getUTCMonth() === 0 ? `${year(d)}` : month(d)) };
  }
  return { at: nth, label: (d) => `${d.getUTCDate()} ${month(d)}` };
}

function drawHistory(by) {
  const bucket = BUCKETS[by];
  const { interval, format } = bucket;
  const starts = interval.range(interval.floor(from), d3.utcDay.offset(to, 1));
  const margin = { top: 8, right: 32, bottom: 24, left: 48 };
  const { at, label } = ticks(starts, bucket, Math.max(1, Math.floor((width - margin.left - margin.right) / 80)));
  d3.select(section).selectAll('figure').remove();

  for (const currency of currencies) {
    const sums = d3.rollup(data.postings.filter((p) => p.currency === currency),
      (v) => ({ value: d3.sum(v, (p) => p.amount), count: v.length }), (p) => interval.floor(parse(p.date)).getTime());
    const values = starts.map((start) => sums.get(start.getTime())?.value ?? 0);
    const counts = starts.map((start) => sums.get(start.getTime())?.count ?? 0);

    const x = d3.scaleBand(d3.range(starts.length), [margin.left, width - margin.right]).padding(0.15);
    const y = d3.scaleLinear([Math.min(0, d3.min(values)), Math.max(0, d3.max(values))], [height - margin.bottom, margin.top]).nice();
    const svg = figure(currency);

    svg.append('g').selectAll('a').data(d3.range(starts.length)).join('a')
      .attr('href', bucket.param ? (i) => link({ period: bucket.param(starts[i]) }) : null)
      .attr('aria-label', (i) => `${format(starts[i])}: ${money(values[i], currency)}`)
      .append('rect')
      .attr('class', (i) => (values[i] < 0 ? 'bar debit' : 'bar'))
      .attr('x', (i) => x(i)).attr('width', x.bandwidth())
      .attr('y', (i) => y(Math.max(0, values[i]))).attr('height', (i) => Math.abs(y(values[i]) - y(0)))
      .on('pointerenter pointermove', (event, i) => showTip(event, format(starts[i]), values[i], currency, counts[i]))
      .on('pointerleave', hideTip);

    svg.append('g').attr('transform', `translate(0,${height - margin.bottom})`)
      .call(d3.axisBottom(x).tickValues(at).tickFormat((i) => label(starts[i])).tickSizeOuter(0));
    if (y.domain()[0] < 0) svg.append('line').attr('class', 'zero').attr('x1', margin.left).attr('x2', width - margin.right).attr('y1', y(0)).attr('y2', y(0));
    svg.append('g').attr('transform', `translate(${margin.left},0)`)
      .call(d3.axisLeft(y).ticks(5).tickFormat(short).tickSizeOuter(0));
  }
}

function history() {
  const options = FINER[data.period.resolution];
  let by = DEFAULT[data.period.resolution];
  if (options.length > 1) {
    const nav = d3.select(section).insert('nav', ':first-child').attr('class', 'tabs').attr('aria-label', 'Agrupar por');
    const buttons = nav.selectAll('button').data(options).join('button').attr('type', 'button')
      .attr('aria-pressed', (name) => name === by).text((name) => BUCKETS[name].label);
    buttons.on('click', (_, name) => {
      by = name;
      buttons.attr('aria-pressed', (other) => other === by);
      drawHistory(by);
    });
  }
  drawHistory(by);
}

// The balance by day: the opening balance plus the running sum of the postings,
// as a step line from the first day of the period to its last (or today), one
// figure per currency, in the report sign. A day is not a period, so nothing
// links. The tooltip follows the pointer to the balance of the day under it.
const day = (d) => `${d.getUTCDate()} ${month(d)}`;
function balance() {
  const margin = { top: 8, right: 32, bottom: 24, left: 48 };
  const end = d3.utcDay.offset(to, 1);
  const x = d3.scaleUtc([from, end], [margin.left, width - margin.right]);
  const slots = Math.max(1, Math.floor((width - margin.left - margin.right) / 80));
  // Ticks on the 1st of months read as the month, January as the year; ticks on days read as `d mmm`.
  const ticks = x.ticks(slots);
  const label = ticks.every((d) => d.getUTCDate() === 1) ? (d) => (d.getUTCMonth() === 0 ? `${year(d)}` : month(d)) : day;
  const at = d3.bisector((p) => p[0]).right;

  for (const currency of [...new Set([...Object.keys(data.opening), ...currencies])]) {
    const sums = d3.rollup(data.postings.filter((p) => p.currency === currency), (v) => d3.sum(v, (p) => p.amount), (p) => p.date);
    let running = data.opening[currency] ?? 0;
    const points = [[from, running]];
    for (const date of [...sums.keys()].sort()) points.push([parse(date), (running += sums.get(date))]);
    points.push([end, running]);
    const y = d3.scaleLinear([Math.min(0, d3.min(points, (p) => p[1])), Math.max(0, d3.max(points, (p) => p[1]))], [height - margin.bottom, margin.top]).nice();
    const svg = figure(currency);

    svg.append('path').attr('class', 'balance')
      .attr('d', d3.line().curve(d3.curveStepAfter).x((p) => x(p[0])).y((p) => y(p[1]))(points));
    svg.append('g').attr('transform', `translate(0,${height - margin.bottom})`)
      .call(d3.axisBottom(x).tickValues(ticks).tickFormat(label).tickSizeOuter(0));
    if (y.domain()[0] < 0) svg.append('line').attr('class', 'zero').attr('x1', margin.left).attr('x2', width - margin.right).attr('y1', y(0)).attr('y2', y(0));
    svg.append('g').attr('transform', `translate(${margin.left},0)`)
      .call(d3.axisLeft(y).ticks(5).tickFormat(short).tickSizeOuter(0));
    svg.append('rect').attr('class', 'hover')
      .attr('x', margin.left).attr('y', margin.top).attr('width', width - margin.left - margin.right).attr('height', height - margin.top - margin.bottom)
      .on('pointerenter pointermove', (event) => {
        const when = d3.utcDay.floor(x.invert(d3.pointer(event, svg.node())[0]));
        const p = points[Math.max(0, at(points, when, 0, points.length - 1) - 1)];
        showTip(event, `${day(when)} ${year(when)}`, p[1], currency);
      })
      .on('pointerleave', hideTip);
  }
}

// Treemaps of the matched amount by group: the first segment under the account,
// or the transaction's payee. A group at or below zero has no area and is left
// out; groups under 1 % of the total merge into Otras, which links nowhere, and
// so does the group with no name.
const account = query.get('account');
const GROUPS = {
  accounts: { key: (p) => p.account.slice(account.length).split(':')[1] ?? '', none: 'Sin subcuenta',
    href: (name) => link({ account: `${account}:${name}` }) },
  payees: { key: (p) => p.payee ?? '', none: 'Sin contraparte', href: (name) => link({ q: name }) },
};

function tree(group) {
  const { key, none, href } = GROUPS[group];
  for (const currency of currencies) {
    const sums = d3.rollup(data.postings.filter((p) => p.currency === currency), (v) => ({ value: d3.sum(v, (p) => p.amount), count: v.length }), key);
    const leaves = [...sums].filter(([, { value }]) => value > 0).map(([name, { value, count }]) => ({ name, value, count }));
    const total = d3.sum(leaves, (leaf) => leaf.value);
    const small = leaves.filter((leaf) => leaf.value < total / 100);
    const kept = small.length > 1
      ? [...leaves.filter((leaf) => leaf.value >= total / 100), { name: 'Otras', value: d3.sum(small, (leaf) => leaf.value), count: d3.sum(small, (leaf) => leaf.count), other: true }]
      : leaves;
    const root = d3.treemap().size([width, height]).padding(1)(
      d3.hierarchy({ children: kept }).sum((d) => d.value).sort((a, b) => b.value - a.value));
    const label = (d) => d.data.name || none;
    // The tone is the share of the largest tile.
    const largest = root.leaves()[0].value;

    const tile = figure(currency).selectAll('a').data(root.leaves()).join('a')
      .attr('class', (d) => `t${step(d.value / largest)}`)
      .attr('href', (d) => (d.data.name && !d.data.other ? href(d.data.name) : null))
      .attr('aria-label', (d) => `${label(d)}: ${money(d.value, currency)}`)
      .on('pointerenter pointermove', (event, d) => showTip(event, label(d), d.value, currency, d.data.count))
      .on('pointerleave', hideTip);
    tile.append('rect').attr('class', 'tile')
      .attr('x', (d) => d.x0).attr('y', (d) => d.y0).attr('width', (d) => d.x1 - d.x0).attr('height', (d) => d.y1 - d.y0);
    // A line of text only where it fits: about 7.5 px per mono character, 14 px per line.
    const line = (row, text) => tile.filter((d) => d.x1 - d.x0 > text(d).length * 7.5 + 8 && d.y1 - d.y0 > row * 14 + 6)
      .append('text').attr('class', 'label')
      .attr('x', (d) => d.x0 + 4).attr('y', (d) => d.y0 + row * 14).text(text);
    line(1, label);
    line(2, (d) => money(d.value, currency));
  }
}

// The Sankey of the income statement, over the leaves of Income and Expenses in
// MXN. Income flows into Ingresos, Ingresos into Gastos and the net, Gastos into
// the expense accounts. The width picks the depth, about 160 px per column, and
// each side goes as deep as its own accounts. A leaf whose net is negative (a
// refund larger than the spend) moves to the other side with its absolute value
// and keeps its ancestors there, so the hubs can exceed the tables by that much;
// the net cannot. A subtree under 1 % of its side folds into Otras under its
// parent, which links nowhere. A node is d3-sankey's max(in, out): a parent with
// postings of its own shows the gap unlinked.
function sankey() {
  const height = fill();
  const leaves = data.rows.map((r) => ({ parts: r.account.split(':'), income: r.account.startsWith('Income') !== (r.amount < 0), value: Math.abs(r.amount) }));
  const side = (leaf) => (leaf.income ? 'in' : 'out');
  const income = d3.sum(leaves, (l) => (l.income ? l.value : 0));
  const expenses = d3.sum(leaves, (l) => (l.income ? 0 : l.value));
  const fit = Math.max(1, Math.floor((width / 160 - 2) / 2));
  const sums = new Map();
  for (const leaf of leaves) {
    for (let d = 1; d < leaf.parts.length; d += 1) {
      const key = `${side(leaf)}/${leaf.parts.slice(0, d + 1).join(':')}`;
      sums.set(key, (sums.get(key) ?? 0) + leaf.value);
    }
  }
  const nodes = new Map();
  const links = new Map();
  const node = (id, props) => nodes.get(id) ?? nodes.set(id, { id, ...props }).get(id);
  const flow = (source, target, value) => {
    if (value <= 0) return;
    const key = `${source.id}>${target.id}`;
    const l = links.get(key) ?? links.set(key, { source: source.id, target: target.id, value: 0 }).get(key);
    l.value += value;
  };
  const ingresos = node('Income', { label: 'Ingresos', account: 'Income', income: true, depth: 0, hub: true });
  const gastos = node('Expenses', { label: 'Gastos', account: 'Expenses', income: false, depth: 0, hub: true });

  for (const leaf of leaves) {
    let prev = leaf.income ? ingresos : gastos;
    for (let d = 1; d <= Math.min(fit, leaf.parts.length - 1); d += 1) {
      const account = leaf.parts.slice(0, d + 1).join(':');
      const key = `${side(leaf)}/${account}`;
      const small = sums.get(key) < (leaf.income ? income : expenses) / 100;
      const next = small ? node(`${prev.id}/otras`, { label: 'Otras', income: leaf.income, depth: d })
        : node(key, { label: leaf.parts[d], account, income: leaf.income, depth: d });
      if (leaf.income) flow(next, prev, leaf.value); else flow(prev, next, leaf.value);
      if (small) break;
      prev = next;
    }
  }
  flow(ingresos, gastos, Math.min(income, expenses));
  if (income > expenses) flow(ingresos, node('net', { label: 'Utilidad neta', income: false, depth: 0, net: 'gain' }), income - expenses);
  if (expenses > income) flow(node('net', { label: 'Pérdida neta', income: true, depth: 0, net: 'loss' }), gastos, expenses - income);
  // Columns by depth from the hubs outward, each side as deep as it turned out.
  const deepest = (income) => d3.max([...nodes.values()].filter((n) => n.income === income), (n) => n.depth);
  const [dIn, dOut] = [deepest(true), deepest(false)];
  for (const n of nodes.values()) n.column = n.income ? dIn - n.depth : dIn + 1 + n.depth;

  const graph = d3.sankey().nodeId((d) => d.id).nodeAlign((d) => d.column).nodeSort(null)
    .nodeWidth(12).nodePadding(8).extent([[0, 4], [width, height - 4]])({ nodes: [...nodes.values()], links: [...links.values()] });
  // Nodes and flows are named alike in the tooltips: the full account, or the label when there is none.
  const name = (d) => d.account ?? d.label;
  // The tone is the side, or the net's own; a flow takes the tone of the node it feeds, and a loss keeps its own.
  const tone = (d) => d.net ?? (d.income ? 'income' : 'expense');
  const svg = figure('MXN', height);
  svg.append('g').selectAll('path').data(graph.links).join('path').attr('class', (d) => `flow ${tone(d.source.net ? d.source : d.target)}`)
    .attr('d', d3.sankeyLinkHorizontal()).attr('stroke-width', (d) => Math.max(1, d.width))
    .on('pointerenter pointermove', (event, d) => showTip(event, `${name(d.source)} → ${name(d.target)}`, d.value, 'MXN'))
    .on('pointerleave', hideTip);
  const a = svg.append('g').selectAll('a').data(graph.nodes).join('a')
    .attr('href', (d) => (d.account ? `/journal?account=${encodeURIComponent(d.account)}&period=${encodeURIComponent(data.period)}` : null))
    .attr('aria-label', (d) => `${name(d)}: ${money(d.value, 'MXN')}`)
    .on('pointerenter pointermove', (event, d) => showTip(event, name(d), d.value, 'MXN'))
    .on('pointerleave', hideTip);
  a.append('rect').attr('class', (d) => `tile ${tone(d)}`)
    .attr('x', (d) => d.x0).attr('y', (d) => d.y0).attr('width', (d) => d.x1 - d.x0).attr('height', (d) => Math.max(0, d.y1 - d.y0));
  // The label beside the node, on the side away from the edge. A hub's goes on its left, over the band
  // into it, where no other label sits. A thin node has only the tooltip.
  const left = (d) => !d.hub && d.x0 < width / 2;
  a.filter((d) => d.hub || d.net || d.y1 - d.y0 >= 12)
    .append('text').attr('class', 'label').attr('dy', '0.35em')
    .attr('x', (d) => (left(d) ? d.x1 + 6 : d.x0 - 6)).attr('y', (d) => (d.y0 + d.y1) / 2)
    .attr('text-anchor', (d) => (left(d) ? 'start' : 'end'))
    .text((d) => `${d.label} ${short(d.value)}`);
}

// The icicle of the balance sheet: the Assets accounts in MXN, one column per depth,
// each cell as tall as its value, biggest first. A cell with children zooms in on a
// click (or Enter) and fills the height; the focus, in the first column, zooms back
// out to its parent. A leaf links to the journal of its account. About 160 px per
// column, at least two. An account with a balance of its own and children is taller
// than its children by that much. The tone is the cell's share of its parent.
function icicle() {
  const height = fill();
  const root = d3.stratify().path((r) => r.account.replaceAll(':', '/'))(data.rows)
    .sum((d) => d?.amount ?? 0).sort((a, b) => b.value - a.value);
  const columns = Math.min(root.height + 1, Math.max(2, Math.floor(width / 160)));
  const column = width / columns;
  // d3.partition's x is the cell's vertical span here and y its horizontal one, as in d3's example.
  d3.partition().size([height, (root.height + 1) * column])(root);
  const name = (d) => d.id.slice(1).replaceAll('/', ':');
  const label = (d) => (d.parent ? d.id.slice(d.id.lastIndexOf('/') + 1) : 'Activos');
  const svg = figure('MXN', height);
  const cell = svg.selectAll('a').data(root.descendants()).join('a')
    .attr('class', (d) => `t${step(d.parent ? d.value / d.parent.value : 1)}`)
    .attr('href', (d) => (d.children ? null : `/journal?account=${encodeURIComponent(name(d))}&period=${encodeURIComponent(data.period)}`))
    .attr('role', (d) => (d.children ? 'button' : null))
    .attr('aria-label', (d) => `${name(d)}: ${money(d.value, 'MXN')}`)
    .on('click', (_, d) => d.children && zoom(d))
    .on('keydown', (event, d) => {
      if (!d.children || (event.key !== 'Enter' && event.key !== ' ')) return;
      event.preventDefault();
      zoom(d);
    })
    .on('pointerenter pointermove', (event, d) => showTip(event, name(d), d.value, 'MXN'))
    .on('pointerleave', hideTip);
  const rect = cell.append('rect').attr('class', 'tile').attr('width', (d) => d.y1 - d.y0);
  // The name and the amount, each only where it fits the column: about 7.5 px per mono character.
  const line = (row, text) => cell.filter((d) => text(d).length * 7.5 + 8 <= column)
    .append('text').attr('class', 'label').attr('x', 4).attr('y', row * 14).text(text);
  const lines = [[1, line(1, label)], [2, line(2, (d) => money(d.value, 'MXN'))]];

  let focus;
  const motion = matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 750;
  // `p` fills the height from the first column. A cell off the columns takes no Tab,
  // and a line shows only where the cell is tall enough for it.
  function show(p, duration) {
    focus = p;
    root.each((d) => {
      d.to = { top: ((d.x0 - p.x0) / (p.x1 - p.x0)) * height, bottom: ((d.x1 - p.x0) / (p.x1 - p.x0)) * height, left: d.y0 - p.y0 };
    });
    const t = svg.transition().duration(duration);
    const seen = (d) => d.to.left >= 0 && d.to.left < width && d.to.bottom > 0 && d.to.top < height;
    cell.attr('tabindex', (d) => (seen(d) ? 0 : -1))
      .transition(t).attr('transform', (d) => `translate(${d.to.left},${d.to.top})`);
    rect.transition(t).attr('height', (d) => d.to.bottom - d.to.top);
    for (const [row, text] of lines) text.transition(t).attr('opacity', (d) => +(seen(d) && d.to.bottom - d.to.top > row * 14 + 6));
  }
  function zoom(d) {
    const p = d === focus ? d.parent : d;
    if (p) show(p, motion);
  }
  show(root, 0);
}

// Drawn once the stylesheet is in, so the block's width is the laid-out one, not the unstyled page.
function draw() {
  width = section.clientWidth;
  const charts = { sankey, icicle, history, balance };
  (charts[data.chart] ?? tree)(data.chart);
}
if (document.readyState === 'complete') draw(); else window.addEventListener('load', draw);
