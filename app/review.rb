# frozen_string_literal: true

module Frijolero
  # Revisar: the unclassified rows of one statement as one form. A save applies every row, adds the
  # rules that the person asked for, runs the account's rules on the rows left (StatementReview),
  # checks the ledger once, and commits and pushes once. Reopens App to keep app.rb a table of contents.
  class App
    STALE_REVIEW = 'El estado de cuenta cambió mientras lo revisabas (una corrida o un pull). ' \
                   'Esto es lo que tiene ahora: elige otra vez.'

    post '/accounts/:account/:yymm/review', PERIOD do
      rules_account!
      account, period = params.values_at(:account, :yymm)
      path = statement_paths(account, period)[:beancount]
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(path)

      done = Ledger.lock { save_review(path, "#{account} #{period}") }
      redirect review_redirect(account, period, done), 303
    rescue StatementReview::Invalid => e
      show_review(account, period, 422, error: e.message, errors: e.rows)
    rescue LedgerEdit::Stale
      show_review(account, period, 409, error: STALE_REVIEW, values: {})
    rescue LedgerEdit::Invalid, Psych::SyntaxError => e
      show_review(account, period, 422, error: e.message)
    rescue Reports::Error => e
      show_review(account, period, 502, error: "No se pudo validar el ledger: #{e.message}")
    end

    helpers do
      # The rows that Revisar offers: one Expenses:FIXME posting, which the chosen account replaces.
      def review_rows(rows) = rows.select { |row| row[:accounts].count(StatementReview::FIXME) == 1 }

      # The form as sent: { line => { 'account', 'payee', 'narration', 'rule', 'pattern' } }.
      def review_values = params['choice'].is_a?(Hash) ? params['choice'] : {}

      # A refused save: the page again, with the values that the person typed unless they are stale.
      def show_review(account, period, status, **review)
        self.status(status)
        statement_page(account, period, view: :review, review: { values: review_values }.merge(review))
      end

      # Revisar's form: what a refused save shows again, the autocomplete and the guesses.
      # The other views read none of it.
      def review_locals(account, period, view, review)
        return {} unless view == :review

        { review: { error: nil, errors: {}, values: {} }.merge(review), accounts: LedgerAccounts.active,
          payees: LedgerAccounts.payees, **suggest_locals(account, period) }
      end

      # Under the ledger's lock: { classified:, rules:, remaining:, push: }. The digest is the file
      # that the page showed: a job or a pull since then may have moved the lines.
      def save_review(path, label)
        text = File.read(path)
        raise LedgerEdit::Stale unless params[:digest] == Digest::SHA256.hexdigest(text)

        review = StatementReview.new(path, rules: rules_content, accounts: LedgerAccounts.active).apply(review_values)
        return review.counts unless review.changed?(text)

        write_review(path, text, review)
        review.counts.merge(push: push_review(label))
      end
    end

    helpers do
      # The rules file is written after the check passes, so a refused save leaves both files as they were.
      def write_review(path, text, review)
        LedgerEdit.new(file: ledger_relative(path), line: nil, checker: self.class.reports)
                  .save(original: text, edited: review.text)
        File.write(Config.rules_path(params[:account]), review.rules) unless review.added.empty?
      end

      # The files are saved and committed either way: a failed push only says so.
      def push_review(label)
        self.class.repo.commit_and_push("Revisión #{label}")
        nil
      rescue LedgerRepo::Error => e
        e.message
      end
    end

    helpers do
      def review_redirect(account, period, done)
        query = { classified: done[:classified], new_rules: (done[:rules] if done[:rules].positive?),
                  push: done[:push] }.compact
        "/accounts/#{Rack::Utils.escape_path(account)}/#{period}#{'/review' if done[:remaining].positive?}?" \
          "#{Rack::Utils.build_query(query)}"
      end

      def review_notice
        text = [count_of(params[:classified].to_i, 'clasificada', 'clasificadas'),
                count_of(params[:new_rules].to_i, 'regla nueva', 'reglas nuevas')].compact.join(', ')
        text = 'Nada que guardar' if text.empty?
        params[:push] ? "#{text}. Guardado, pero no se pudo subir: #{params[:push]}" : text
      end

      def count_of(count, one, many) = ("#{count} #{count == 1 ? one : many}" if count.positive?)
    end
  end
end
