// The chart block of the journal and of the income statement. Ruby embeds the
// chart's name and its rows in #chart-data: for the journal, the period and the
// matched postings (date, currency, amount in the report sign, account, payee);
// for the Sankey, the period as a param and the leaves of Income and Expenses.
// d3 does the rest. Dates are plain days: utcParse and the utc intervals keep
// them as written.
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

// The tip is kept inside the block: one that overhung an edge widened the page,
// and the scrollbar shifted the whole view.
function showTip(event, when, value, currency) {
  const [px, py] = d3.pointer(event, section);
  tip.select('.when').text(when);
  tip.select('data').attr('value', value).text(money(value, currency));
  tip.attr('hidden', null);
  const half = tip.node().offsetWidth / 2;
  tip.style('left', `${Math.min(Math.max(px, half), section.clientWidth - half)}px`).style('top', `${py}px`);
}
const hideTip = () => tip.attr('hidden', true);

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
      (v) => d3.sum(v, (p) => p.amount), (p) => interval.floor(parse(p.date)).getTime());
    const values = starts.map((start) => sums.get(start.getTime()) ?? 0);

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
      .on('pointerenter pointermove', (event, i) => showTip(event, format(starts[i]), values[i], currency))
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
    const sums = d3.rollup(data.postings.filter((p) => p.currency === currency), (v) => d3.sum(v, (p) => p.amount), key);
    const leaves = [...sums].filter(([, value]) => value > 0).map(([name, value]) => ({ name, value }));
    const total = d3.sum(leaves, (leaf) => leaf.value);
    const small = leaves.filter((leaf) => leaf.value < total / 100);
    const kept = small.length > 1
      ? [...leaves.filter((leaf) => leaf.value >= total / 100), { name: 'Otras', value: d3.sum(small, (leaf) => leaf.value), other: true }]
      : leaves;
    const root = d3.treemap().size([width, height]).padding(1)(
      d3.hierarchy({ children: kept }).sum((d) => d.value).sort((a, b) => b.value - a.value));
    const label = (d) => d.data.name || none;
    // Four tints of ink by the square root of the share of the largest tile, like a
    // grey scale; labels reverse out on the two dark steps and none lands on a midtone.
    const largest = root.leaves()[0].value;
    const tint = (d) => { const r = Math.sqrt(d.value / largest); return r >= 0.75 ? 1 : r >= 0.5 ? 0.7 : r >= 0.25 ? 0.25 : 0.1; };

    const tile = figure(currency).selectAll('a').data(root.leaves()).join('a')
      .attr('href', (d) => (d.data.name && !d.data.other ? href(d.data.name) : null))
      .attr('aria-label', (d) => `${label(d)}: ${money(d.value, currency)}`)
      .on('pointerenter pointermove', (event, d) => showTip(event, label(d), d.value, currency))
      .on('pointerleave', hideTip);
    tile.append('rect').attr('class', 'tile').attr('fill-opacity', tint)
      .attr('x', (d) => d.x0).attr('y', (d) => d.y0).attr('width', (d) => d.x1 - d.x0).attr('height', (d) => d.y1 - d.y0);
    // A line of text only where it fits: about 7.5 px per mono character, 14 px per line.
    const line = (row, text) => tile.filter((d) => d.x1 - d.x0 > text(d).length * 7.5 + 8 && d.y1 - d.y0 > row * 14 + 6)
      .append('text').attr('class', (d) => (tint(d) >= 0.7 ? 'label on-ink' : 'label'))
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
  // It fills the viewport under its own top.
  const height = Math.max(320, window.innerHeight - section.getBoundingClientRect().top - window.scrollY - 40);
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

// Drawn once the stylesheet is in, so the block's width is the laid-out one, not the unstyled page.
function draw() {
  width = section.clientWidth;
  if (data.chart === 'sankey') sankey(); else if (data.chart === 'history') history(); else tree(data.chart);
}
if (document.readyState === 'complete') draw(); else window.addEventListener('load', draw);
