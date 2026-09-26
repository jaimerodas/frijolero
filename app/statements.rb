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
    # The statement's views: `view` is only beancount and `action` only edit, so …/pdf and the
    # other routes under a period never land on the statement page.
    STATEMENT_VIEWS = { mustermann_opts: { capture: { yymm: /\d{4}/, view: 'beancount', action: 'edit' } } }.freeze

    helpers do
      # Beancount text → one `span.line#L<n>` per line, colored, split on "\n" with the trailing
      # empty one kept, as editor.js does. The lines of a directive with an error get `.err`.
      def beancount_html(text, errors = [])
        lines = text.empty? ? [''] : text.split("\n", -1)
        lines.zip(error_lines(lines, errors)).each_with_index.map do |(line, error), i|
          title = error && %( title="#{h("#{error[:code]} #{error[:message]}")}")
          %(<span class="line#{' err' if error}" id="L#{i + 1}"#{title}>#{beancount_line(line)}</span>)
        end.join
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

    # One URL per view, so a reload or a link lands on the view it names: the movements at
    # /accounts/<Key>/<YYMM>, the Beancount text at …/beancount, and the editor at …/beancount/edit.
    get '/accounts/:account/:yymm(/:view(/:action)?)?', STATEMENT_VIEWS do
      account = params[:account]
      period = params[:yymm]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(account)
      # The period menu submits ?period= to the page it is on, and lands on the same view of that statement.
      if params[:period].to_s.match?(/\A\d{4}\z/) && params[:period] != period
        redirect "/accounts/#{Rack::Utils.escape_path(account)}/#{params[:period]}#{'/beancount' if params[:view]}"
      end

      paths = statement_paths(account, period)
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(paths[:beancount])

      config = Config.accounts[account]
      pipeline = Pipeline.for(config)
      # Only the Default pipeline's transactions read as rows; an investment statement
      # (Fintual, Alpaca, CETES) shows the extraction summary and the Beancount text only.
      rows = StatementRows.read(paths[:beancount], config) if pipeline.runs_detailer?
      data = JSON.parse(File.read(paths[:json])) if rows.nil? && File.exist?(paths[:json])
      beancount = File.read(paths[:beancount])

      erb :statement, locals: {
        account: account, period: period,
        view: params[:view] ? :beancount : :entries, editing: params[:action] == 'edit',
        summary: data && pipeline.summary(data),
        rows: rows,
        totals: rows && StatementRows.totals(rows),
        periods: Config.statement_periods(account),
        fixme_count: beancount.scan(/^\s+Expenses:FIXME\b/).size,
        beancount: beancount,
        file: paths[:beancount].delete_prefix("#{File.expand_path(Config.ledger_dir)}/"),
        notice: statement_notice
      }
    end

    helpers do
      def statement_notice
        return "#{params[:detailed]} clasificadas, #{params[:remaining]} sin clasificar" if params[:detailed]
        return 'Guardado' if params[:saved]

        'Reglas guardadas. Aplica las reglas para usarlas.' if params[:rules]
      end
    end

    get '/accounts/:account/:yymm/pdf', PERIOD do
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])

      redirect self.class.s3.presigned_url(Config.pdf_key(params[:account], params[:yymm])), 302
    end

    post '/accounts/:account/:yymm/detail', PERIOD do
      account, period = params.values_at(:account, :yymm)
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(account)
      beancount = statement_paths(account, period)[:beancount]
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(beancount)
      halt 404, 'Esta cuenta no usa reglas' unless rules?(account)
      rules = Config.rules_path(account)
      halt 422, 'No hay reglas para esta cuenta' unless File.exist?(rules)

      stats = BeancountDetailer.new(beancount, rules).run
      self.class.repo.commit_and_push("detail #{account} #{period}") if stats[:detailed].positive?
      redirect_path = "/accounts/#{Rack::Utils.escape_path(account)}/#{period}"
      redirect "#{redirect_path}?detailed=#{stats[:detailed]}&remaining=#{stats[:remaining]}", 303
    end
  end
end
