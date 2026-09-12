# frozen_string_literal: true

module Frijolero
  # Statement page and its actions. Reopens App to keep app.rb a table of contents.
  class App
    # Matched on escaped text: a string is `&quot;…&quot;`, and a comment needs a space or a line start before
    # the `;` because entities end in one. The order matters: a string swallows what it holds.
    BEANCOUNT_TOKEN = /
      (?<head>^\d{4}-\d{2}-\d{2}\ \S+)
      | (?<comment>(?<!\S);.*)
      | (?<string>&quot;.*?&quot;)
      | (?<account>(?:Assets|Liabilities|Equity|Income|Expenses)(?::[\w-]+)+)
      | (?<amount>-?\d[\d,]*(?:\.\d+)?\ [A-Z][A-Z0-9._-]*)
    /x

    # The period segment is four digits, so /accounts/<Key>/config and /rules never land here.
    PERIOD = { mustermann_opts: { capture: { yymm: /\d{4}/ } } }.freeze

    helpers do
      # Beancount text → one `span.line#L<n>` per line, colored. The lines are
      # split on "\n" with the trailing empty one kept, the same as the editor's
      # render in public/editor.js, which has the JS copy of BEANCOUNT_TOKEN.
      def beancount_html(text)
        lines = text.split("\n", -1)
        lines = [''] if lines.empty?
        lines.each_with_index.map { |line, i| %(<span class="line" id="L#{i + 1}">#{beancount_line(line)}</span>) }.join
      end
    end

    helpers do
      # One line → HTML with a span per date, flag, account and amount. Display only.
      # A line that matches nothing is just escaped text, so a hand edit never breaks the page.
      def beancount_line(text)
        Rack::Utils.escape_html(text).gsub(BEANCOUNT_TOKEN) do
          m = Regexp.last_match
          kind = m.names.find { |n| m[n] }
          kind == 'head' ? beancount_head(m[:head]) : beancount_span(kind, m[0])
        end
      end

      def beancount_head(head)
        date, flag = head.split(' ', 2)
        %(<span class="bc-date">#{date}</span> <span class="bc-flag#{' bc-warn' if flag == '!'}">#{flag}</span>)
      end

      # Strings are matched so that an account or a `;` inside a narration stays plain.
      def beancount_span(kind, text)
        klass = case kind
                when 'string' then return text
                when 'account' then text.start_with?('Expenses:FIXME') ? 'bc-account bc-fixme' : 'bc-account'
                when 'amount' then text.start_with?('-') ? 'debit' : 'credit'
                else "bc-#{kind}"
                end
        %(<span class="#{klass}">#{text}</span>)
      end

      # The two files a processed statement leaves in the ledger.
      def statement_paths(account, period)
        { json: Config.statement_path(account, period, 'json'),
          beancount: Config.statement_path(account, period, 'beancount') }
      end
    end

    get '/accounts/:account/:yymm', PERIOD do
      account = params[:account]
      period = params[:yymm]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(account)
      halt 404, 'Periodo inválido' unless period.match?(/\A\d{4}\z/)

      paths = statement_paths(account, period)
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(paths[:beancount])

      config = Config.accounts[account]
      pipeline = Pipeline.for(config)
      # Only the Default pipeline's transactions read as rows; an investment statement
      # (Fintual, Plata, CETES) shows the extraction summary and the Beancount text only.
      rows = StatementRows.read(paths[:beancount], config) if pipeline.runs_detailer?
      data = JSON.parse(File.read(paths[:json])) if rows.nil? && File.exist?(paths[:json])
      beancount = File.read(paths[:beancount])

      erb :statement, locals: {
        account: account,
        period: period,
        summary: data && pipeline.summary(data),
        rows: rows,
        totals: rows && StatementRows.totals(rows),
        neighbours: statement_neighbours(account, period),
        fixme_count: beancount.scan(/^\s+Expenses:FIXME\b/).size,
        beancount: beancount,
        file: ledger_relative(paths[:beancount]),
        notice: statement_notice
      }
    end

    helpers do
      # [previous, next] periods that have a `.beancount` for this account, nil at each end.
      def statement_neighbours(account, period)
        dir = File.dirname(Config.statement_path(account, period, 'beancount'))
        name = /\A#{Regexp.escape(account)} (\d{4})\.beancount\z/
        periods = Dir.children(dir).filter_map { |file| name.match(file)&.[](1) }.sort
        index = periods.index(period)
        [(periods[index - 1] if index.positive?), periods[index + 1]]
      end

      def statement_notice
        return "#{params[:detailed]} clasificadas, #{params[:remaining]} sin clasificar" if params[:detailed]
        return 'Guardado' if params[:saved]

        'Reglas guardadas. Aplica las reglas para usarlas.' if params[:rules]
      end
    end

    get '/accounts/:account/:yymm/pdf', PERIOD do
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])
      halt 404, 'Periodo inválido' unless params[:yymm].match?(/\A\d{4}\z/)

      redirect self.class.b2.presigned_url(Config.pdf_key(params[:account], params[:yymm])), 302
    end

    post '/accounts/:account/:yymm/detail', PERIOD do
      account, period = params.values_at(:account, :yymm)
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(account)
      halt 404, 'Periodo inválido' unless period.match?(/\A\d{4}\z/)
      beancount = statement_paths(account, period)[:beancount]
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(beancount)
      halt 404, 'Esta cuenta no usa reglas' unless rules?(account)
      rules = Config.rules_path(account)
      halt 422, 'No hay reglas para esta cuenta' unless File.exist?(rules)

      stats = BeancountDetailer.new(beancount, rules).run
      self.class.repo.commit_and_push("detail #{account} #{period}") if stats[:detailed].any?
      redirect_path = "/accounts/#{Rack::Utils.escape_path(account)}/#{period}"
      redirect "#{redirect_path}?detailed=#{stats[:detailed].size}&remaining=#{stats[:remaining].size}", 303
    end
  end
end
