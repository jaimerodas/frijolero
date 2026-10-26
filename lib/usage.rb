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
      'gpt-5.6-sol' => %w[4.00 0.40 20.00],
      'gpt-6-sol' => %w[2.00 0.20 10.00]
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
      # costs 0 and a warning, and never raises.
      def record(prompt:, model:, input_tokens:, cached_tokens:, output_tokens:)
        cost = cost_micros(model, input_tokens, cached_tokens, output_tokens)
        ledger = Ledger.current
        DB.insert('INSERT INTO usage (user_id, ledger_id, prompt, model, input_tokens, cached_tokens, ' \
                  'output_tokens, cost_micros, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                  ledger.owner_id, ledger.id, prompt, model, input_tokens, cached_tokens, output_tokens, cost,
                  Time.now.utc.iso8601)
        cost
      end

      # The cost of the user in the calendar month of `now`, in local time.
      def month_micros(user_id, now: Time.now)
        from, to = month_bounds(now.getlocal)
        DB.first('SELECT COALESCE(SUM(cost_micros), 0) AS total FROM usage WHERE user_id = ? AND at >= ? AND at < ?',
                 user_id, from, to)['total']
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
