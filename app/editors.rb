# frozen_string_literal: true

require 'yaml'

module Frijolero
  # Rules and accounts editors. Reopens App to keep app.rb a table of contents.
  class App
    # Raised by parse_yaml_hash! and the accounts validator; the message is shown
    # to the user on the re-rendered editor.
    class EditorError < StandardError; end

    get '/rules/:account' do
      rules_account!
      path = Config.rules_path(params[:account])
      content = File.exist?(path) ? File.read(path) : "start_with: {}\ninclude: {}\n"
      render_editor(**rules_locals(params[:account], content: content, notice: saved_notice))
    end

    post '/rules/:account' do
      rules_account!
      content = params[:content].to_s
      data = parse_yaml_hash!(content)
      Detailer::Rules.new(data).matches_for(description: 'probe', amount: 0)
      save_config!(Config.rules_path(params[:account]), content, "rules #{params[:account]}")
      redirect "/rules/#{Rack::Utils.escape_path(params[:account])}?saved=1", 303
    rescue EditorError, Psych::SyntaxError, NoMethodError, TypeError, ArgumentError => e
      render_editor(status: 422, **rules_locals(params[:account], content: content, error: e.message))
    end

    post '/rules/:account/from' do
      rules_account!
      path = Config.rules_path(params[:account])
      content = File.exist?(path) ? File.read(path) : ''
      description = params[:description].to_s.strip
      if description.empty?
        halt 200, render_editor(**rules_locals(params[:account], content: content, error: 'Falta la descripción'))
      end

      data = YAML.safe_load(content) || {}
      (data['start_with'] ||= {})[description] ||= { 'payee' => '', 'narration' => '', 'account' => 'Expenses:' }
      new_content = YAML.dump(data)
      render_editor(**rules_locals(params[:account], content: new_content, notice: rule_added_notice(description)))
    end

    helpers do
      def rules_account!
        halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])
        halt 404, 'Esta cuenta no usa reglas' unless rules?(params[:account])
      end

      # Every editor save ends the same way: the ledger repo commits and pushes.
      def commit_config(message)
        self.class.repo.commit_and_push(message)
      end

      def render_editor(status: 200, **locals)
        defaults = { notice: nil, error: nil }
        self.status(status)
        erb :editor, locals: defaults.merge(locals)
      end

      def rules_locals(account, **extra)
        action = "/rules/#{Rack::Utils.escape_path(account)}"
        { title: "Reglas de #{account}", action: action }.merge(extra)
      end

      def rule_added_notice(description)
        "Regla nueva para «#{description}» (monto #{params[:amount]}). Completa payee y account, luego guarda."
      end

      def saved_notice
        params[:saved] && 'Guardado'
      end
    end

    helpers do
      # Raises EditorError (never Psych::SyntaxError) so every caller has one
      # exception type to rescue for "the text isn't valid YAML".
      def parse_yaml_hash!(text)
        data = YAML.safe_load(text.to_s)
        raise EditorError, 'El YAML debe ser un mapeo (hash)' unless data.is_a?(Hash)

        data
      rescue Psych::SyntaxError => e
        raise EditorError, "YAML inválido: #{e.message}"
      end

      def validate_accounts_yaml!(content)
        data = parse_yaml_hash!(content)
        data.each do |key, value|
          raise EditorError, "#{key}: falta beancount_account" unless account_entry_valid?(value)
        end
      end

      def account_entry_valid?(value)
        value.is_a?(Hash) && value['beancount_account'].is_a?(String) && !value['beancount_account'].strip.empty?
      end

      def save_config!(path, content, message)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        commit_config(message)
      end
    end
  end
end
