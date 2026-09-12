// The journal's chart block. Ruby embeds the chart's name, the period and the
// matched postings (date, currency, amount in the report sign, account, payee)
// in #chart-data; d3 does the rest. Dates are plain days: utcParse and the utc
// intervals keep them as written.
const block = document.getElementById('chart-data');
const data = JSON.parse(block.textContent);
const section = block.parentElement;
const query = new URLSearchParams(location.search);
const width = section.clientWidth;
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
const currencies = [...new Set(data.postings.map((p) => p.currency))];
const tip = d3.select(section).append('div').attr('class', 'tip').attr('hidden', true);
tip.append('span').attr('class', 'when');
tip.append('data');

function showTip(event, when, value, currency) {
  const [px, py] = d3.pointer(event, section);
  tip.select('.when').text(when);
  tip.select('data').attr('value', value).text(money(value, currency));
  tip.style('left', `${px}px`).style('top', `${py}px`).attr('hidden', null);
}
const hideTip = () => tip.attr('hidden', true);

function figure(currency) {
  const fig = d3.select(section).append('figure');
  if (currencies.length > 1) fig.append('figcaption').text(currency);
  return fig.append('svg').attr('viewBox', [0, 0, width, height]);
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

    const tile = figure(currency).selectAll('a').data(root.leaves()).join('a')
      .attr('href', (d) => (d.data.name && !d.data.other ? href(d.data.name) : null))
      .attr('aria-label', (d) => `${label(d)}: ${money(d.value, currency)}`)
      .on('pointerenter pointermove', (event, d) => showTip(event, label(d), d.value, currency))
      .on('pointerleave', hideTip);
    tile.append('rect').attr('class', 'tile')
      .attr('x', (d) => d.x0).attr('y', (d) => d.y0).attr('width', (d) => d.x1 - d.x0).attr('height', (d) => d.y1 - d.y0);
    // A line of text only where it fits: about 7.5 px per mono character, 14 px per line.
    const line = (row, text) => tile.filter((d) => d.x1 - d.x0 > text(d).length * 7.5 + 8 && d.y1 - d.y0 > row * 14 + 6)
      .append('text').attr('class', 'label').attr('x', (d) => d.x0 + 4).attr('y', (d) => d.y0 + row * 14).text(text);
    line(1, label);
    line(2, (d) => money(d.value, currency));
  }
}

if (data.chart === 'history') history(); else tree(data.chart);
