# frozen_string_literal: true

require 'yaml'

module Frijolero
  # Rules and accounts editors. Reopens App to keep app.rb a table of contents.
  class App
    # Raised by parse_yaml_hash! and the accounts validator; the message is shown
    # to the user on the re-rendered editor.
    class EditorError < StandardError; end

    get '/accounts/:account/rules' do
      rules_account!
      render_editor(**rules_locals(params[:account], content: rules_content, notice: saved_notice))
    end

    post '/accounts/:account/rules' do
      rules_account!
      content = params[:content].to_s
      data = parse_yaml_hash!(content)
      Detailer::Rules.new(data).matches_for(description: 'probe', amount: 0)
      save_config!(Config.rules_path(params[:account]), content, "rules #{params[:account]}")
      redirect back_path ? "#{back_path}?rules=1" : "#{rules_locals(params[:account])[:action]}?saved=1", 303
    rescue EditorError, Psych::SyntaxError, NoMethodError, TypeError, ArgumentError => e
      render_editor(status: 422, **rules_locals(params[:account], content: content, error: e.message))
    end

    post '/accounts/:account/rules/from' do
      rules_account!
      content = rules_content
      description = params[:description].to_s.strip
      if description.empty?
        halt 200, render_editor(**rules_locals(params[:account], content: content, error: 'Falta la descripción'))
      end

      rules = YAML.safe_load(content)&.dig('start_with')
      known = rules.is_a?(Hash) && rules.key?(description)
      new_content, caret = known ? [content, nil] : with_rule(content, description)
      render_editor(**rules_locals(params[:account], content: new_content, caret: caret,
                                                     notice: rule_added_notice(description)))
    end

    helpers do
      # The account's rules file, or the empty template when it has none yet, with LF line
      # endings as the browser shows them (a save before the fix below wrote CRLF).
      def rules_content
        path = Config.rules_path(params[:account])
        File.exist?(path) ? File.read(path).gsub("\r\n", "\n") : "start_with: {}\ninclude: {}\n"
      end

      def rules_account!
        halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])
        halt 404, 'Esta cuenta no usa reglas' unless rules?(params[:account])
      end

      # The statement page sends its own path with "Hacer regla", so the editor
      # can offer the way back and the save can return there. Nothing else is honoured.
      def back_path
        params[:back] if params[:back].to_s.match?(%r{\A/accounts/[^/?#]+/\d{4}\z})
      end

      def render_editor(status: 200, **locals)
        defaults = { notice: nil, error: nil, back: back_path, account: nil, tab: nil, caret: nil }
        self.status(status)
        erb :editor, locals: defaults.merge(locals)
      end

      def rules_locals(account, **extra)
        action = "/accounts/#{Rack::Utils.escape_path(account)}/rules"
        { title: "Reglas de #{account}", action: action, account: account, tab: :rules }.merge(extra)
      end
    end

    # "Hacer regla": a new entry, written into the text.
    helpers do
      # [content with an empty `start_with` entry for `description` closing that section, the
      # offset after its `account: `]. Text, not YAML.dump, so the file keeps its comments,
      # quotes and order. The fields are empty, not '', because the rules skip an empty field:
      # a payee left blank keeps the transaction's own. The caret goes where the autocomplete helps.
      def with_rule(content, description)
        content += "\n" unless content.empty? || content.end_with?("\n")
        lines = content.sub(/^start_with:\s*\{\s*\}[ \t]*$/, 'start_with:').lines
        at = rule_slot(lines)
        lines.insert(at, rule_entry(description))
        [lines.join, lines[..at].join.size - 1]
      end

      # The key as YAML writes a value, quoted only when it must be; as a key Psych would switch
      # to the `? key` form past 128 characters, and a BBVA description often is longer.
      def rule_entry(description)
        key = YAML.dump(description, line_width: -1).delete_prefix('--- ').chomp
        "  #{key}:\n    payee:\n    narration:\n    account: \n"
      end

      # Where the entry goes: after the last indented line of `start_with:`, before the next
      # top-level key; a file without the section gets one.
      def rule_slot(lines)
        head = lines.index { |line| line.start_with?('start_with:') }
        return lines.push("start_with:\n").size unless head

        body = lines[(head + 1)..].take_while { |line| !line.match?(/\A[^\s#]/) }
        last = body.rindex { |line| line.match?(/\A\s+\S/) }
        last ? head + last + 2 : head + 1
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
        File.write(path, content.gsub("\r\n", "\n")) # a browser submits a textarea with CRLF
        self.class.repo.commit_and_push(message)
      end
    end
  end
end
