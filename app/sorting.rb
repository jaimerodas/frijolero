# frozen_string_literal: true

module Frijolero
  # The order of the journal: `?sort=`, newest first by default. Reopens App.
  class App
    SORTS = %w[date-desc date-asc amount-desc amount-asc].freeze

    helpers do
      # A valid `?sort=`, else the default. An amount sort needs matched
      # postings, so without an account it means the default too.
      def journal_sort
        sort = params[:sort]
        ok = SORTS.include?(sort) && (sort.start_with?('date') || !params[:account].to_s.empty?)
        ok ? sort : SORTS.first
      end

      # `sort=<value>` for the journal links, nil for the default.
      def sort_param(sort)
        "sort=#{sort}" unless sort == SORTS.first
      end

      # A header link that flips its key: under date-desc, "Fecha ▾" links to
      # date-asc; under an amount sort, "Fecha" links to date-desc. HTML.
      def sort_link(key, label, period)
        current = journal_sort.start_with?(key)
        desc = current && journal_sort.end_with?('desc')
        glyph = (desc ? ' ▾' : ' ▴') if current
        href = "/journal?#{report_query(period, sort: "#{key}-#{desc ? 'asc' : 'desc'}")}"
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
  end
end
