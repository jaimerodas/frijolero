# frozen_string_literal: true

require 'date'
require 'time'

module Frijolero
  # One row in `usage` for each model call, with its cost. The owner of the ledger pays.
  module Usage
    # USD per 1 million tokens: input, cached input, output. That is the same number as
    # micro-dollars per token, so the cost in micros needs no scale factor.
    PRICES = {
      'gpt-5.4-mini' => %w[0.75 0.075 4.50],
      'gpt-6.1-sol' => %w[2.00 0.10 10.00]
    }.transform_values { |prices| prices.map { |price| Rational(price) }.freeze }.freeze

    # The monthly cap of a user whose users.monthly_cap_micros is NULL: 3 USD.
    DEFAULT_CAP_MICROS = 3_000_000

    class << self
      def cap_micros(user_id)
        DB.first('SELECT monthly_cap_micros FROM users WHERE id = ?', user_id)&.fetch('monthly_cap_micros') ||
          DEFAULT_CAP_MICROS
      end

      # At the cap or past it: the app makes no new model call for this user this month.
      def capped?(user_id, now: Time.now) = month_micros(user_id, now: now) >= cap_micros(user_id)

      # 1_234_567 → '1.23', for the pages. The records keep the micros.
      def usd(micros) = format('%.2f', Rational(micros, 1_000_000))

      # Returns the cost in micro-dollars. The call is already paid, so an unknown model
      # costs 0 and a warning, and never raises. The directory of `pdf` is the token of
      # its upload (incoming/<token>/), so a second extraction of one upload is a retry.
      def record(prompt:, model:, pdf:, input_tokens:, cached_tokens:, output_tokens:)
        cost = cost_micros(model, input_tokens, cached_tokens, output_tokens)
        ledger = Ledger.current
        DB.insert('INSERT INTO usage (user_id, ledger_id, upload, prompt, model, input_tokens, cached_tokens, ' \
                  'output_tokens, cost_micros, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                  ledger.owner_id, ledger.id, File.basename(File.dirname(pdf)), prompt, model, input_tokens,
                  cached_tokens, output_tokens, cost, Time.now.utc.iso8601)
        cost
      end

      # The cost of the user in the calendar month of `now`, in local time.
      def month_micros(user_id, now: Time.now)
        from, to = month_bounds(now.getlocal)
        DB.first('SELECT COALESCE(SUM(cost_micros), 0) AS total FROM usage WHERE user_id = ? AND at >= ? AND at < ?',
                 user_id, from, to)['total']
      end

      # One row per local month with a call, newest first: the files that reached the model,
      # the extractions that read a file again (retries), and the cost. A row from before
      # the upload column has no upload, so its extraction counts as a file of its own.
      def history(user_id)
        DB.execute(<<~SQL, user_id)
          SELECT month, COUNT(DISTINCT file) AS files,
                 SUM(extraction) - COUNT(DISTINCT CASE WHEN extraction THEN file END) AS retries,
                 SUM(cost_micros) AS micros
          FROM (SELECT strftime('%Y-%m', at, 'localtime') AS month, cost_micros, prompt <> 'classify' AS extraction,
                       COALESCE(upload, CASE WHEN prompt <> 'classify' THEN 'call ' || id END) AS file
                FROM usage WHERE user_id = ?)
          GROUP BY month ORDER BY month DESC
        SQL
      end

      private

      # The UTC ISO 8601 start of this month and of the next, from local midnights.
      def month_bounds(local)
        first = Date.new(local.year, local.month, 1)
        [first, first.next_month].map { |day| Time.new(day.year, day.month, 1).utc.iso8601 }
      end

      def cost_micros(model, input, cached, output)
        input_price, cached_price, output_price = PRICES[model]
        unless input_price
          Log.puts "Warning: no price for model #{model}; its cost is recorded as 0"
          return 0
        end

        (((input - cached) * input_price) + (cached * cached_price) + (output * output_price)).round
      end
    end
  end
end
