# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'

class WebEditorsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeRepo
    attr_reader :messages

    def initialize
      @messages = []
    end

    def commit_and_push(message)
      @messages << message
    end
  end

  def setup
    @previous_rack_env = ENV.fetch('RACK_ENV', nil)
    ENV['RACK_ENV'] = 'test'
    require 'frijolero/web/app'

    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      BBVA TDC:
        beancount_account: "Assets:BBVA"
    YAML

    @repo = FakeRepo.new
    Frijolero::Web::App.repo = @repo
  end

  def teardown
    restore_env('RACK_ENV', @previous_rack_env)
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::Web::App.repo = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::Web::App
  end

  def test_rules_editor_shows_a_default_template_when_no_file_exists
    get '/rules/AMEX'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'start_with: {}'
  end

  def test_saving_valid_rules_writes_the_file_verbatim_and_commits
    yaml = <<~YAML
      # comment
      start_with:
        OXXO:
          payee: "Oxxo"
          account: "Expenses:Comida"
      include: {}
    YAML

    post '/rules/AMEX', content: yaml

    assert_equal 303, last_response.status
    assert_equal '/rules/AMEX?saved=1', URI(last_response.location).request_uri
    assert_equal yaml, File.read(rules_path('AMEX'))
    assert_equal ['rules AMEX'], @repo.messages
  end

  def test_invalid_yaml_syntax_is_rejected_without_writing_or_committing
    post '/rules/AMEX', content: 'start_with: [unclosed'

    assert_equal 422, last_response.status
    refute_empty last_response.body[/class="error"[^>]*>([^<]+)/, 1].to_s
    refute File.exist?(rules_path('AMEX'))
    assert_empty @repo.messages
  end

  def test_structurally_wrong_rules_are_rejected
    post '/rules/AMEX', content: 'start_with: 5'

    assert_equal 422, last_response.status
    refute File.exist?(rules_path('AMEX'))
    assert_empty @repo.messages
  end

  def test_rules_editor_route_handles_an_account_with_a_space
    get '/rules/BBVA%20TDC'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'action="/rules/BBVA%20TDC"'
  end

  def test_make_a_rule_prefills_a_new_pattern_without_saving
    FileUtils.mkdir_p(File.dirname(rules_path('AMEX')))
    File.write(rules_path('AMEX'), <<~YAML)
      start_with:
        UBER:
          payee: "Uber"
          account: "Expenses:Transporte"
    YAML

    post '/rules/AMEX/from', description: 'OXXO 123', amount: '-50'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'UBER'
    assert_includes last_response.body, 'OXXO 123'
    assert_includes last_response.body, 'account: &#39;Expenses:&#39;'
    assert_equal <<~YAML, File.read(rules_path('AMEX'))
      start_with:
        UBER:
          payee: "Uber"
          account: "Expenses:Transporte"
    YAML
    assert_empty @repo.messages
  end

  def test_make_a_rule_does_not_duplicate_an_existing_pattern
    FileUtils.mkdir_p(File.dirname(rules_path('AMEX')))
    File.write(rules_path('AMEX'), <<~YAML)
      start_with:
        OXXO 123:
          payee: "Oxxo"
          account: "Expenses:Comida"
    YAML

    post '/rules/AMEX/from', description: 'OXXO 123', amount: '-50'

    assert_equal 1, last_response.body.scan('OXXO 123:').size
  end

  def test_make_a_rule_with_blank_description_shows_an_error
    post '/rules/AMEX/from', description: '  ', amount: '-50'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Falta la descripción'
  end

  def test_unknown_account_rules_editor_404s
    get '/rules/Nope'

    assert_equal 404, last_response.status
  end

  private

  def rules_path(account)
    Frijolero::Config.rules_path(account)
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
