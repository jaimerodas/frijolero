# frozen_string_literal: true

module Frijolero
  # Revisar's guesses (Suggestions): after each good job, and from "Sugerir cuentas" for a
  # statement processed before them. The call always runs on the job queue, never in a request,
  # because it can take longer than the proxy waits. Reopens App to keep app.rb a table of contents.
  class App
    SUGGEST_LABEL = 'Sugerencias '

    post '/accounts/:account/:yymm/suggest', PERIOD do
      rules_account!
      account, period = params.values_at(:account, :yymm)
      halt 404, 'No existe ese estado de cuenta' unless File.exist?(Config.statement_path(account, period, 'beancount'))
      extraction_allowed!

      client = self.class.client
      ledger = Ledger.current
      job = self.class.jobs.push(label: "#{SUGGEST_LABEL}#{account} #{period}") do
        Ledger.with(ledger) { write_suggestions(client, account, period) }
      end
      redirect "/jobs/#{job.id}", 303
    end

    helpers do
      def write_suggestions(client, account, period)
        Log.puts "Sugerencias guardadas: #{Suggestions.new(client).write(account, period)}"
      end

      # After a good statement, outside the lock. A failure is a line of the job's log, never a
      # failed job: the statement is already pushed, and the button can ask again.
      def suggest_after_job(client, account, period)
        return unless client && rules?(account)
        return Log.puts('Sin sugerencias: llegaste al límite del mes') if Usage.capped?(Ledger.current.owner_id)

        write_suggestions(client, account, period)
      rescue StandardError => e
        Log.puts "✗ Sin sugerencias: #{e.message}"
      end

      # Revisar's part: the guesses, the corrida that is making them, and the button while
      # there are none, none is coming and the model can be asked.
      def suggest_locals(account, period)
        label = "#{SUGGEST_LABEL}#{account} #{period}"
        pending = self.class.jobs.all.find { |job| job.label == label && !job.done? }
        { guesses: Suggestions.read(account, period), suggesting: pending,
          can_suggest: !pending && can_suggest?(account, period) }
      end

      def can_suggest?(account, period)
        self.class.client && !File.exist?(Suggestions.path(account, period)) && !Usage.capped?(Ledger.current.owner_id)
      end
    end
  end
end
