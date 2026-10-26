# frozen_string_literal: true

# Sinatra fixes its environment (and with it host authorization) the first time
# sinatra/base loads, so this must come before the app.
ENV['RACK_ENV'] = 'test'

require_relative '../app/app'
require 'minitest/autorun'
require 'minitest/mock'
require 'English'
require 'fileutils'
require 'tmpdir'
module TestHelpers
  FIXTURES_DIR = File.expand_path('fixtures', __dir__)
  TEMPLATES_DIR = File.expand_path('../templates', __dir__)

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  def template_path(name)
    File.join(TEMPLATES_DIR, name)
  end

  def with_temp_dir(&)
    Dir.mktmpdir(&)
  end

  # Runs rustledger, the checker the app runs, and returns its output and status.
  # Skips the test when rustledger is not installed.
  def rledger(*args)
    skip 'rledger not installed' unless system("command -v #{Frijolero::Config.rledger} > /dev/null 2>&1")

    [IO.popen([Frijolero::Config.rledger, *args], err: %i[child out], &:read), $CHILD_STATUS]
  end

  # Runs the block with `values` in ENV (nil unsets) and puts the old values back.
  def with_env(values)
    old = ENV.to_h.slice(*values.keys)
    values.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    values.each_key { |k| ENV.delete(k) }
    ENV.merge!(old)
  end

  def without_env(*keys, &) = with_env(keys.to_h { |k| [k, nil] }, &)

  def s3_env = Frijolero::S3::ENV_KEYS.to_h { |k| [k, 'x'] }

  # An App outside a request, for a test that renders one view. The views read the
  # request for ledger_path, so it gets an empty one.
  def view_app = Frijolero::App.new!.tap { |app| app.request = Sinatra::Request.new(Rack::MockRequest.env_for('/')) }

  # The prefix that LedgerScope gives the requests of one ledger. A web test passes
  # 'SCRIPT_NAME' => LEDGER_ROOT in the env to get a page as production serves it.
  LEDGER_ROOT = '/l/test0000'

  # The paths outside this ledger: Login's /logout, the pages of Ledgers and Admin, and
  # the dashboard of another ledger (the switcher).
  OUTSIDE_LEDGERS = %r{\A/(logout|ledgers(/.*)?|admin(/.*)?|l/[a-z0-9]+/)?\z}

  # Each href, action, formaction and src of `html` that starts with / is inside
  # LEDGER_ROOT, except the static files and OUTSIDE_LEDGERS.
  def assert_ledger_links(html)
    stray = html.scan(%r{(?:href|action|src)="(/[^"]*)"}).flatten.reject do |path|
      path.start_with?("#{LEDGER_ROOT}/") || path.match?(OUTSIDE_LEDGERS) ||
        File.file?(File.join(Frijolero::App.public_folder, path[/\A[^?#]*/]))
    end
    assert_empty stray, 'links outside the ledger'
  end

  # A fresh DATA_DIR with one ledger, `test`, as the current ledger of this thread, the
  # way a request or a job has one. Returns its repo directory, with config/ inside.
  # leave_test_ledger undoes it. The ledger has no row: with_db_ledger is for the
  # tests that need the database.
  def enter_test_ledger(main_file: 'main.beancount')
    @test_ledger_before = [Thread.current[:frijolero_ledger], ENV.fetch('DATA_DIR', nil)]
    @test_data_dir = Dir.mktmpdir
    ENV['DATA_DIR'] = @test_data_dir
    dir = File.join(@test_data_dir, 'ledgers', 'test')
    Frijolero::Ledger.current = Frijolero::Ledger.new(id: 'test', owner_id: 1, name: 'Prueba', main_file: main_file,
                                                      pdf_prefix: 'frijolero', dir: dir,
                                                      repo_dir: File.join(dir, 'repo'))
    FileUtils.mkdir_p(File.join(dir, 'repo', 'config'))
    File.join(dir, 'repo')
  end

  def leave_test_ledger
    FileUtils.rm_rf(@test_data_dir)
    ledger, data_dir = @test_ledger_before
    Frijolero::Ledger.current = ledger
    data_dir ? ENV['DATA_DIR'] = data_dir : ENV.delete('DATA_DIR')
  end

  def with_ledger_dir(**)
    dir = enter_test_ledger(**)
    yield dir
  ensure
    leave_test_ledger
  end

  # enter_test_ledger, plus the owner (user 1, an admin) and the ledger as rows of a
  # fresh database. leave_test_ledger undoes it.
  def enter_db_ledger(main_file: 'main.beancount')
    dir = enter_test_ledger(main_file: main_file)
    now = Time.now.utc.iso8601
    owner = Frijolero::DB.insert("INSERT INTO users (email, role, status, created_at) VALUES (?, 'admin', 'active', ?)",
                                 'admin@example.com', now)
    Frijolero::DB.execute('INSERT INTO ledgers (id, owner_id, name, main_file, pdf_prefix, created_at) ' \
                          "VALUES ('test', ?, 'Prueba', ?, 'frijolero', ?)", owner, main_file, now)
    Frijolero::Ledger.current = Frijolero::Ledger.find('test')
    dir
  end

  def with_db_ledger(**)
    dir = enter_db_ledger(**)
    yield dir
  ensure
    leave_test_ledger
  end
end
