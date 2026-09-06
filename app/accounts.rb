# frozen_string_literal: true

module Frijolero
  # Accounts list and per-account PDF history. Reopens App to keep app.rb a table of contents.
  class App
    get '/accounts' do
      open, closed = Config.accounts.partition { |_k, c| !c['closed'] }
      erb :accounts, locals: { open: open.to_h, closed: closed.to_h }
    end

    # The whole file, for adding an account. The per-account editor below is for the rest.
    get '/accounts/yaml' do
      content = File.exist?(Config.accounts_file) ? File.read(Config.accounts_file) : ''
      render_editor(**yaml_locals(content: content, notice: saved_notice))
    end

    post '/accounts/yaml' do
      content = params[:content].to_s
      validate_accounts_yaml!(content)
      save_config!(Config.accounts_file, content, 'accounts.yaml')
      redirect '/accounts/yaml?saved=1', 303
    rescue EditorError => e
      render_editor(status: 422, **yaml_locals(content: content, error: e.message))
    end

    get '/accounts/:key' do
      key = params[:key]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(key)

      rows = account_pdf_rows(key)
      erb :account, locals: { key: key, rows: rows, error: nil }
    rescue B2::Error => e
      status 502
      erb :account, locals: { key: key, rows: [], error: e.message }
    end

    get '/accounts/:key/config' do
      key = params[:key]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(key)

      block = AccountBlock.extract(File.read(Config.accounts_file), key)
      halt 404, 'Cuenta desconocida' unless block

      render_editor(**account_config_locals(key, content: block, notice: saved_notice))
    end

    post '/accounts/:key/config' do
      key = params[:key]
      halt 404, 'Cuenta desconocida' unless Config.accounts.key?(key)

      content = params[:content].to_s
      data = parse_yaml_hash!(content)
      raise EditorError, "El bloque debe definir solo #{key}" unless data.keys == [key]
      raise EditorError, "#{key}: falta beancount_account" unless account_entry_valid?(data[key])

      text = AccountBlock.replace(File.read(Config.accounts_file), key, content)
      validate_accounts_yaml!(text)
      save_config!(Config.accounts_file, text, "accounts #{key}")
      redirect "/accounts/#{Rack::Utils.escape_path(key)}/config?saved=1", 303
    rescue EditorError => e
      render_editor(status: 422, **account_config_locals(key, content: content, error: e.message))
    end

    helpers do
      def yaml_locals(**extra)
        { title: 'Cuentas', action: '/accounts/yaml', back: '/accounts' }.merge(extra)
      end

      def account_config_locals(key, **extra)
        action = "/accounts/#{Rack::Utils.escape_path(key)}/config"
        { title: "Config de #{key}", action: action, back: "/accounts/#{Rack::Utils.escape_path(key)}" }.merge(extra)
      end

      def account_pdf_rows(key)
        rows = self.class.b2.list(Config.pdf_prefix(key)).filter_map { |entry| account_pdf_row(key, entry) }
        rows.sort_by { |row| row[:period] }.reverse
      end

      def account_pdf_row(key, entry)
        parsed = AccountConfig.parse_filename(entry[:key])
        return unless parsed && parsed[0] == key

        period = parsed[1]
        { period: period, size: entry[:size], uploaded_at: entry[:last_modified],
          processed: File.exist?(Config.statement_path(key, period, 'beancount')) }
      end
    end
  end
end
