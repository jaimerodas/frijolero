# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class UsageTest < Minitest::Test
  include TestHelpers

  Usage = Frijolero::Usage
  DB = Frijolero::DB

  def record(model: 'gpt-5.6-sol', input: 0, cached: 0, output: 0)
    Usage.record(prompt: 'default', model: model, input_tokens: input, cached_tokens: cached, output_tokens: output)
  end

  def add_row(user_id, at, cost)
    DB.insert('INSERT INTO usage (user_id, ledger_id, prompt, model, input_tokens, output_tokens, cost_micros, at) ' \
              "VALUES (?, 'test', 'default', 'gpt-6-sol', 0, 0, ?, ?)", user_id, cost, at)
  end

  # gpt-5.6-sol is 4.00 / 0.40 / 20.00: 1000 * 4 + 500 * 20 = 14000 micro-dollars (US$0.014).
  def test_cost_of_a_known_model
    with_db_ledger { assert_equal 14_000, record(input: 1000, output: 500) }
  end

  # 600 fresh * 4.00 + 400 cached * 0.40 = 2560, not 1000 * 4.00.
  def test_cached_tokens_cost_the_cached_rate
    with_db_ledger { assert_equal 2560, record(input: 1000, cached: 400) }
  end

  # 1 token at 0.075 is 0.075 micros; 10 of them are 0.75, which rounds to 1.
  def test_cost_is_exact_and_rounded_to_an_integer
    with_db_ledger { assert_equal 1, record(model: 'gpt-5.4-mini', input: 10, cached: 10) }
  end

  def test_unknown_model_costs_zero_and_warns
    sink = StringIO.new
    Frijolero::Log.sink = sink
    with_db_ledger do
      assert_equal 0, record(model: 'claude-x', input: 1000, output: 500)
      assert_equal 0, DB.first('SELECT cost_micros FROM usage')['cost_micros']
    end
    assert_includes sink.string, 'claude-x'
  ensure
    Frijolero::Log.sink = $stdout
  end

  def test_record_writes_the_owner_and_the_ledger_of_the_current_ledger
    with_db_ledger do
      record(input: 10, cached: 4, output: 2)

      row = DB.first('SELECT * FROM usage')
      assert_equal [Frijolero::Ledger.current.owner_id, 'test', 'default', 'gpt-5.6-sol', 10, 4, 2],
                   row.values_at('user_id', 'ledger_id', 'prompt', 'model', 'input_tokens', 'cached_tokens',
                                 'output_tokens')
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, row['at'])
    end
  end

  def test_month_micros_counts_only_this_month_and_this_user
    with_db_ledger do
      me = Frijolero::Ledger.current.owner_id
      other = DB.insert("INSERT INTO users (email, role, status, created_at) VALUES ('b@example.com', 'user', " \
                        "'active', '2026-01-01T00:00:00Z')")
      now = Time.new(2026, 10, 15, 12)
      add_row(me, Time.new(2026, 10, 1).utc.iso8601, 100)
      add_row(me, Time.new(2026, 10, 31, 23, 59, 59).utc.iso8601, 20)
      add_row(me, Time.new(2026, 9, 30, 23, 59, 59).utc.iso8601, 1000)
      add_row(me, Time.new(2026, 11, 1).utc.iso8601, 2000)
      add_row(other, Time.new(2026, 10, 15).utc.iso8601, 50_000)

      assert_equal 120, Usage.month_micros(me, now: now)
      assert_equal 50_000, Usage.month_micros(other, now: now)
      assert_equal 0, Usage.month_micros(me, now: Time.new(2026, 8, 1))
    end
  end

  def test_month_micros_in_december_reaches_the_next_year
    with_db_ledger do
      me = Frijolero::Ledger.current.owner_id
      add_row(me, Time.new(2026, 12, 31, 23).utc.iso8601, 7)
      add_row(me, Time.new(2027, 1, 1).utc.iso8601, 900)

      assert_equal 7, Usage.month_micros(me, now: Time.new(2026, 12, 5))
    end
  end

  def test_every_model_of_the_prompts_has_a_price
    models = Dir[File.expand_path('../prompts/*/spec.json', __dir__)].map { |f| JSON.parse(File.read(f))['model'] }

    assert_empty models.uniq - Usage::PRICES.keys
  end
end
