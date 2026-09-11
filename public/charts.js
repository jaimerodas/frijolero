// The journal's chart block. Ruby embeds the period and the matched postings
// (date, currency, amount in the report sign) in #chart-data; d3 does the rest.
// Dates are plain days: utcParse and the utc intervals keep them as written.
const block = document.getElementById('chart-data');
const data = JSON.parse(block.textContent);
const section = block.parentElement;
const parse = d3.utcParse('%Y-%m-%d');
const from = parse(data.period.from);
const to = parse(data.period.to);

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

// Finest first. A bucket is offered only when it is finer than the page's resolution.
const BUCKETS = {
  day: { label: 'Día', interval: d3.utcDay, format: (d) => `${d.getUTCDate()} ${MESES[d.getUTCMonth()]}` },
  month: { label: 'Mes', interval: d3.utcMonth, format: (d) => `${MESES[d.getUTCMonth()]} ${d.getUTCFullYear()}` },
  quarter: { label: 'Trimestre', interval: d3.utcMonth.every(3), format: (d) => `T${Math.floor(d.getUTCMonth() / 3) + 1} ${d.getUTCFullYear()}` },
  year: { label: 'Año', interval: d3.utcYear, format: (d) => `${d.getUTCFullYear()}` },
};
const FINER = { month: ['day'], quarter: ['day', 'month'], year: ['day', 'month', 'quarter'], all: Object.keys(BUCKETS) };
const DEFAULT = { month: 'day', quarter: 'month', year: 'month', all: 'year' };

const amount = new Intl.NumberFormat('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const currencies = [...new Set(data.postings.map((p) => p.currency))];

function draw(by) {
  const { interval, format } = BUCKETS[by];
  const starts = interval.range(interval.floor(from), d3.utcDay.offset(to, 1));
  const width = section.clientWidth;
  const height = 200;
  const margin = { top: 8, right: 32, bottom: 24, left: 64 };
  d3.select(section).selectAll('figure').remove();

  for (const currency of currencies) {
    const sums = d3.rollup(data.postings.filter((p) => p.currency === currency),
      (v) => d3.sum(v, (p) => p.amount), (p) => interval.floor(parse(p.date)).getTime());
    const values = starts.map((start) => sums.get(start.getTime()) ?? 0);

    const x = d3.scaleBand(d3.range(starts.length), [margin.left, width - margin.right]).padding(0.15);
    const y = d3.scaleLinear([Math.min(0, d3.min(values)), Math.max(0, d3.max(values))], [height - margin.bottom, margin.top]).nice();
    const figure = d3.select(section).append('figure');
    if (currencies.length > 1) figure.append('figcaption').text(currency);
    const svg = figure.append('svg').attr('viewBox', [0, 0, width, height]).attr('role', 'img')
      .attr('aria-label', `${currency} por ${BUCKETS[by].label.toLowerCase()}`);

    svg.append('g').selectAll('rect').data(values).join('rect')
      .attr('class', (v) => (v < 0 ? 'bar debit' : 'bar'))
      .attr('x', (_, i) => x(i)).attr('width', x.bandwidth())
      .attr('y', (v) => y(Math.max(0, v))).attr('height', (v) => Math.abs(y(v) - y(0)))
      .append('title').text((v, i) => `${format(starts[i])}: ${amount.format(v)} ${currency}`);

    const every = Math.max(1, Math.ceil(starts.length / ((width - margin.left - margin.right) / 80)));
    svg.append('g').attr('transform', `translate(0,${y(0)})`)
      .call(d3.axisBottom(x).tickValues(d3.range(0, starts.length, every)).tickFormat((i) => format(starts[i])).tickSizeOuter(0));
    svg.append('g').attr('transform', `translate(${margin.left},0)`)
      .call(d3.axisLeft(y).ticks(5).tickFormat(d3.format(',.0f')).tickSizeOuter(0));
  }
}

const options = FINER[data.period.resolution];
let by = DEFAULT[data.period.resolution];
if (options.length > 1) {
  const nav = d3.select(section).insert('nav', ':first-child').attr('class', 'tabs').attr('aria-label', 'Agrupar por');
  const buttons = nav.selectAll('button').data(options).join('button').attr('type', 'button')
    .attr('aria-pressed', (name) => name === by).text((name) => BUCKETS[name].label);
  buttons.on('click', (_, name) => {
    by = name;
    buttons.attr('aria-pressed', (other) => other === by);
    draw(by);
  });
}
draw(by);
