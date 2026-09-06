# frozen_string_literal: true

module Frijolero
  # Statement page and its actions. Reopens App to keep app.rb a table of contents.
  class App
    helpers do
      # The two files a processed statement leaves in the ledger.
      def statement_paths(account, period)
        { json: Config.statement_path(account, period, 'json'),
          beancount: Config.statement_path(account, period, 'beancount') }
      end
    end

    get '/statements/:account/:yymm' do
      account = params[:account]
      period = params[:yymm]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(account)
      halt 404, 'Periodo inválido' unless period.match?(/\A\d{4}\z/)

      paths = statement_paths(account, period)
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(paths[:beancount])

      data = File.exist?(paths[:json]) ? JSON.parse(File.read(paths[:json])) : nil
      beancount = File.read(paths[:beancount])
      pipeline = Pipeline.for(Config.accounts[account])

      erb :statement, locals: {
        account: account,
        period: period,
        summary: data && pipeline.summary(data),
        # Only the Default pipeline's rows have date/description/amount; an
        # investment statement (Fintual, Plata, CETES) shows summary and preview only.
        transactions: pipeline.runs_detailer? ? data&.dig('transactions') : nil,
        fixme_count: beancount.scan(/^\s+Expenses:FIXME\b/).size,
        beancount: beancount,
        notice: params[:detailed] && "#{params[:detailed]} detalladas, #{params[:remaining]} pendientes"
      }
    end

    get '/statements/:account/:yymm/pdf' do
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])
      halt 404, 'Periodo inválido' unless params[:yymm].match?(/\A\d{4}\z/)

      redirect self.class.b2.presigned_url(Config.pdf_key(params[:account], params[:yymm])), 302
    end

    post '/statements/:account/:yymm/detail' do
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
      redirect_path = "/statements/#{Rack::Utils.escape_path(account)}/#{period}"
      redirect "#{redirect_path}?detailed=#{stats[:detailed].size}&remaining=#{stats[:remaining].size}", 303
    end
  end
end
