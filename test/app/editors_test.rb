# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'

class EditorsTest < Minitest::Test
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
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      BBVA TDC:
        beancount_account: "Assets:BBVA"
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
    YAML

    @repo = FakeRepo.new
    Frijolero::App.repo = @repo
  end

  def teardown
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.repo = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::App
  end

  def test_hacer_regla_keeps_the_way_back_to_the_statement
    post '/accounts/AMEX/rules/from', description: 'OXXO 123', amount: '-50', back: '/accounts/AMEX/2508'

    assert_includes last_response.body, '<a href="/accounts/AMEX/2508">Volver al estado de cuenta</a>'
    assert_includes last_response.body, '<input type="hidden" name="back" value="/accounts/AMEX/2508">'
  end

  def test_saving_from_a_statement_returns_to_it
    post '/accounts/AMEX/rules', content: "start_with: {}\n", back: '/accounts/AMEX/2508'

    assert_equal 303, last_response.status
    assert_equal '/accounts/AMEX/2508?rules=1', URI(last_response.location).request_uri
  end

  def test_back_is_only_honoured_for_a_statement_path
    post '/accounts/AMEX/rules', content: "start_with: {}\n", back: 'https://evil.example/'

    assert_equal '/accounts/AMEX/rules?saved=1', URI(last_response.location).request_uri

    get '/accounts/AMEX/rules', back: '/accounts'

    refute_includes last_response.body, 'Volver al estado de cuenta'
  end

  def test_rules_editor_explains_the_rules_and_the_autocomplete_replaces_the_list
    File.write(File.join(@dir, 'main.beancount'), "2024-01-01 open Liabilities:Amex\n2024-01-01 open Assets:BBVA\n")
    FileUtils.mkdir_p(File.join(@dir, 'config', 'rules'))
    File.write(rules_path('BBVA TDC'), <<~YAML)
      start_with:
        OXXO: { account: "Expenses:Comida" }
        UBER: { account: Expenses:Taxi }
    YAML

    get '/accounts/AMEX/rules'

    refute_includes last_response.body, '<aside'
    assert_includes last_response.body, 'Cómo escribir reglas'

    get '/accounts/yaml'
    refute_includes last_response.body, 'class="accounts"'
  end

  # The rules textarea gets the autocomplete of the Beancount editors, over the open accounts.
  def test_rules_editor_embeds_the_open_accounts_for_the_autocomplete
    File.write(File.join(@dir, 'main.beancount'), "2024-01-01 open Liabilities:Amex\n")

    get '/accounts/AMEX/rules'

    assert_includes last_response.body, '<script type="application/json" class="accounts">["Liabilities:Amex"]</script>'
    assert_includes last_response.body, '<script src="/editor.js" defer></script>'
  end

  def test_rules_editor_shows_a_default_template_when_no_file_exists
    get '/accounts/AMEX/rules'

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

    post '/accounts/AMEX/rules', content: yaml

    assert_equal 303, last_response.status
    assert_equal '/accounts/AMEX/rules?saved=1', URI(last_response.location).request_uri
    assert_equal yaml, File.read(rules_path('AMEX'))
    assert_equal ['rules AMEX'], @repo.messages
  end

  # A browser submits a textarea with CRLF line endings; the file keeps the ledger's LF.
  def test_saving_rules_from_a_browser_writes_lf_line_endings
    post '/accounts/AMEX/rules', content: "start_with:\r\n  OXXO:\r\n    account: Expenses:Comida\r\n"

    assert_equal "start_with:\n  OXXO:\n    account: Expenses:Comida\n", File.read(rules_path('AMEX'))
  end

  # A file saved with CRLF before the fix: the caret counts the text the browser shows, which is LF.
  def test_make_a_rule_on_a_crlf_file_puts_the_caret_on_the_account
    FileUtils.mkdir_p(File.dirname(rules_path('AMEX')))
    File.write(rules_path('AMEX'), "start_with:\r\n  UBER:\r\n    account: Expenses:Taxi\r\ninclude: {}\r\n")

    post '/accounts/AMEX/rules/from', description: 'OXXO', amount: '-50'

    content = textarea_content(last_response.body)
    caret = last_response.body[/data-caret="(\d+)"/, 1].to_i
    refute_includes content, "\r"
    assert_equal '    account: ', content[0...caret].lines.last
  end

  def test_invalid_yaml_syntax_is_rejected_without_writing_or_committing
    post '/accounts/AMEX/rules', content: 'start_with: [unclosed'

    assert_equal 422, last_response.status
    refute_empty last_response.body[/class="error"[^>]*>([^<]+)/, 1].to_s
    refute File.exist?(rules_path('AMEX'))
    assert_empty @repo.messages
  end

  def test_structurally_wrong_rules_are_rejected
    post '/accounts/AMEX/rules', content: 'start_with: 5'

    assert_equal 422, last_response.status
    refute File.exist?(rules_path('AMEX'))
    assert_empty @repo.messages
  end

  def test_rules_editor_route_handles_an_account_with_a_space
    get '/accounts/BBVA%20TDC/rules'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'action="/accounts/BBVA%20TDC/rules"'
  end

  # The textarea's text as the browser gets it.
  def textarea_content(body) = CGI.unescapeHTML(body[%r{<textarea[^>]*>(.*?)</textarea>}m, 1])

  # "Hacer regla" writes the new entry into the text: comments, quotes and order stay, the
  # entry closes the start_with section, and nothing is saved yet.
  def test_make_a_rule_adds_the_entry_as_text_at_the_end_of_start_with
    FileUtils.mkdir_p(File.dirname(rules_path('AMEX')))
    File.write(rules_path('AMEX'), <<~YAML)
      # Reglas de AMEX
      start_with:
        UBER:            # viajes
          payee: "Uber"
          account: "Expenses:Transporte"
      # lo que contiene
      include:
        OXXO: { account: Expenses:Comida }
    YAML
    before = File.read(rules_path('AMEX'))

    post '/accounts/AMEX/rules/from', description: 'OXXO 123', amount: '-50'

    assert_equal 200, last_response.status
    assert_equal <<~YAML, textarea_content(last_response.body)
      # Reglas de AMEX
      start_with:
        UBER:            # viajes
          payee: "Uber"
          account: "Expenses:Transporte"
        OXXO 123:
          payee:
          narration:
          account:\u0020
      # lo que contiene
      include:
        OXXO: { account: Expenses:Comida }
    YAML
    assert_equal before, File.read(rules_path('AMEX'))
    assert_empty @repo.messages
  end

  # The caret goes after `account: `, where the autocomplete takes over.
  def test_make_a_rule_puts_the_caret_on_the_account
    post '/accounts/AMEX/rules/from', description: '*TELCEL', amount: '-50'

    content = textarea_content(last_response.body)
    assert_equal "start_with:\n  \"*TELCEL\":\n    payee:\n    narration:\n    account: \ninclude: {}\n", content
    caret = last_response.body[/data-caret="(\d+)"/, 1].to_i
    assert_equal '    account: ', content[0...caret].lines.last
    assert_equal '*TELCEL', YAML.safe_load(content)['start_with'].keys.first
  end

  def test_make_a_rule_does_not_duplicate_an_existing_pattern
    FileUtils.mkdir_p(File.dirname(rules_path('AMEX')))
    File.write(rules_path('AMEX'), <<~YAML)
      start_with:
        OXXO 123:
          payee: "Oxxo"
          account: "Expenses:Comida"
    YAML

    post '/accounts/AMEX/rules/from', description: 'OXXO 123', amount: '-50'

    assert_equal 1, last_response.body.scan('OXXO 123:').size
  end

  def test_make_a_rule_with_blank_description_shows_an_error
    post '/accounts/AMEX/rules/from', description: '  ', amount: '-50'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Falta la descripción'
  end

  def test_rules_editor_404s_for_an_account_without_rules
    get '/accounts/CETES/rules'
    assert_equal 404, last_response.status

    post '/accounts/CETES/rules', content: "start_with: {}\n"
    assert_equal 404, last_response.status

    post '/accounts/CETES/rules/from', description: 'x', amount: '1'
    assert_equal 404, last_response.status
  end

  def test_unknown_account_rules_editor_404s
    get '/accounts/Nope/rules'

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
