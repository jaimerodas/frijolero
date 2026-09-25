# frozen_string_literal: true

module Frijolero
  # The order of the journal: `?sort=`, newest first by default. Reopens App.
  class App
    SORTS = %w[date-desc date-asc amount-desc amount-asc].freeze
    JOURNAL_PAGE = 200
    # A report sort: `name-asc` (the default), `name-desc`, or `<currency>-asc|desc`, a column of the table.
    REPORT_SORT = /\A(name|[A-Z][A-Z0-9'._-]*)-(asc|desc)\z/

    helpers do
      # A valid `?sort=`, else the default. An amount sort needs matched
      # postings, so without an account it means the default too.
      def journal_sort
        sort = params[:sort]
        ok = SORTS.include?(sort) && (sort.start_with?('date') || !params[:account].to_s.empty?)
        ok ? sort : SORTS.first
      end

      # The order of the report tables: siblings by name or by one currency column.
      def report_sort = params[:sort].to_s.match?(REPORT_SORT) ? params[:sort] : default_sort

      def journal? = request.path_info == '/journal'
      def page_sort = journal? ? journal_sort : report_sort
      def default_sort = journal? ? SORTS.first : 'name-asc'

      # `sort=<value>` for the page's links, nil for its default.
      def sort_param(sort)
        "sort=#{sort}" unless sort == default_sort
      end

      # A header link that flips its key: under date-desc, "Fecha ▾" links to
      # date-asc; under an amount sort, "Fecha" links to date-desc. A key that is
      # not current starts at its natural direction: names ascending, the rest descending. HTML.
      def sort_link(key, label, period)
        current_key, _, direction = page_sort.rpartition('-')
        current = current_key == key
        desc = current ? direction == 'desc' : key == 'name'
        glyph = (desc ? ' ▾' : ' ▴') if current
        href = "#{request.path_info}?#{report_query(period, sort: "#{key}-#{desc ? 'asc' : 'desc'}")}"
        %(<a href="#{Rack::Utils.escape_html(href)}"#{' aria-current="true"' if current}>#{label}#{glyph}</a>)
      end
    end

    helpers do
      # Fills `sum`, the headline of each entry: the matched postings in the
      # report sign, computed once for the view and the sort.
      def journal_sums(rows, sign)
        rows.each do |tx|
          tx[:sum] = Hash.new(BigDecimal('0'))
          tx[:postings].each { |p| p[:amount].each { |c, n| tx[:sum][c] += n * sign } if p[:matched] }
        end
      end

      # Ties keep the ledger order, and an amount tie falls back to the date.
      # ponytail: a sum in several currencies (`?mxn=0`) sorts by the first one.
      def sort_rows(rows)
        sort = journal_sort
        desc = sort.end_with?('desc')
        rows.each_with_index.sort_by do |tx, i|
          value = sort.start_with?('amount') ? tx[:sum].values.first || 0 : tx[:date].jd
          [desc ? -value : value, -tx[:date].jd, i]
        end.map(&:first)
      end
    end

    helpers do
      # Every transaction of the journal with only its matched postings, summed
      # and sorted: the count, the total, the order and the charts read it, and
      # the page fetches its own transactions whole.
      def journal_index(account, period, sign)
        index = self.class.reports.journal_index(account, period.from, period.to, mxn: mxn?, text: params[:q])
        sort_rows(journal_sums(index, sign))
      end

      def journal_total(index)
        index.each_with_object(Hash.new(0)) { |tx, total| tx[:sum].each { |c, n| total[c] += n } }
      end

      # `?page=` clamped to 1..pages, and pages, at least 1.
      def journal_page(count)
        pages = [(count + JOURNAL_PAGE - 1) / JOURNAL_PAGE, 1].max
        [params[:page].to_i.clamp(1, pages), pages]
      end

      # The page of the sorted index, fetched whole, in its order and with its sums,
      # plus the balances that land on this page, merged in by date. `balances` is []
      # outside an account, an amount sort or a text filter (see `journal_balances`).
      def journal_page_rows(index, account, period, balances = [])
        page, pages = journal_page(index.size)
        rows = journal_shown(index, account, period, page)
        return rows if balances.empty?

        desc = journal_sort.end_with?('desc')
        journal_merge(rows, journal_page_balances(balances, rows, page, pages, desc), desc)
      end

      # This page's slice of the sorted index, fetched whole, with its sums.
      def journal_shown(index, account, period, page)
        shown = index.slice((page - 1) * JOURNAL_PAGE, JOURNAL_PAGE)
        whole = journal_whole(account, period, shown.map { |tx| tx[:id] })
        shown.filter_map { |tx| whole[tx[:id]]&.merge(sum: tx[:sum]) }
      end
    end

    helpers do
      # The balances that belong on this page: those dated between its first and last
      # transaction, plus, for the page that holds the newest transactions, the ones
      # after that, and for the page with the oldest, the ones before. A date shared by
      # two pages may show on both. With no transactions at all (a balance-only period,
      # or one whose only page is empty), every balance shows.
      def journal_page_balances(balances, rows, page, pages, desc)
        return balances if rows.empty?

        newest_page, oldest_page = desc ? [1, pages] : [pages, 1]
        dates = rows.map { |tx| tx[:date] }
        lower = dates.min if page != oldest_page
        upper = dates.max if page != newest_page
        balances.select { |b| (lower..upper).cover?(b[:date]) }
      end

      # Transactions and balances of one page, by date. A balance is asserted at the
      # start of its day, so it sits before that day's transactions in date-asc (oldest
      # first) and after them in date-desc; ties otherwise keep each list's own order.
      def journal_merge(rows, page_balances, desc)
        rank = desc ? 1 : -1
        (rows + page_balances).each_with_index.sort_by do |row, i|
          [desc ? -row[:date].jd : row[:date].jd, row[:balance] ? rank : 0, i]
        end.map(&:first)
      end
    end

    helpers do
      # Those transactions with every posting, by id.
      def journal_whole(account, period, ids)
        self.class.reports.journal(account, period.from, period.to, mxn: mxn?, ids: ids).to_h { |tx| [tx[:id], tx] }
      end

      # A link to another page of the same journal; page 1 is the bare query. HTML.
      def journal_page_link(period, number, label, rel)
        href = "/journal?#{report_query(period)}#{"&page=#{number}" if number > 1}"
        %(<a href="#{Rack::Utils.escape_html(href)}" rel="#{rel}">#{label}</a>)
      end

      # The balance assertions of the period, only where the journal can show them
      # cleanly: one account, sorted by date, with no text filter narrowing the rows.
      def journal_balances(account, period)
        return [] if account.empty? || !journal_sort.start_with?('date') || !params[:q].to_s.empty?

        self.class.reports.balances(account, period.from, period.to).map { |row| row.merge(balance: true) }
      end

      # The ledger's own error at a row's line, if any: same file, and the line inside
      # the error's directive.
      def row_error(file, line)
        (ledger_errors || []).find { |e| e[:file] == file && e[:line] <= line && line < e[:end_line] }
      end
    end
  end
end
