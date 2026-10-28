# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'
require_relative '../../app/profile'
require_relative '../../app/ledgers'

# /profile and the delete of a ledger (/ledgers/<id>/delete), outside any ledger. The
# admin owns 'test', the adopted ledger, and 'Casa', a ledger of its own with no remote.
class ProfileTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  def app
    Rack::Builder.new do
      use Frijolero::ProfilePage
      use Frijolero::Ledgers
      run ->(_env) { [200, {}, ['abajo']] }
    end
  end

  def setup
    dir = enter_db_ledger
    Frijolero::Ledger.current = nil
    @owner = Frijolero::Users.find_by_email('admin@example.com')
    env 'frijolero.user', @owner
    @casa = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Casa')
    Frijolero::NewLedger.prepare(@casa.repo_dir)
    @pdfs = Frijolero::LocalPdfs.new(File.join(dir, '..', 'bucket'))
    Frijolero::App.s3 = @pdfs
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(dir, '..', 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(dir, '..', 'incoming'))
  end

  def teardown
    leave_test_ledger
    Frijolero::App.s3 = nil
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
  end

  def test_the_page_lists_the_ledgers_and_offers_the_delete_of_its_own
    get '/profile'

    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, '<a href="/profile" aria-current="page">Mi cuenta</a>'
    assert_includes body, 'admin@example.com'
    assert_includes body, %(<a href="/l/#{@casa.id}/">Casa</a>)
    assert_includes body, %(href="/ledgers/#{@casa.id}/delete")
    refute_includes body, 'href="/ledgers/test/delete"', 'the adopted ledger shares its PDFs'
    assert_includes body, 'sin remoto'
    assert_includes body, 'href="/passkeys"'
  end

  def test_the_page_shows_the_month_against_the_cap_and_the_history
    add_usage(@owner, Time.now, 1_250_000, upload: 'a')
    add_usage(@owner, Time.now, 250_000, upload: 'a')

    get '/profile'

    assert_includes last_response.body, 'Este mes: 1.50 de 3.00 USD.'
    assert_equal %w[1 1 0 1.50], month_row.scan(%r{<td data-label="[^"]+">([^<]*)</td>}).flatten
  end

  # The failures come from the job log of each ledger. Beto has one ledger, so the shared
  # fake job log counts once.
  def test_the_history_counts_the_failed_jobs_of_the_month
    beto = user('beto@example.com')
    Frijolero::Ledger.create(owner_id: beto.id, name: 'Beto')
    Frijolero::App.jobs.push(label: 'AMEX 2610') { raise 'no' }
    Frijolero::App.jobs.work_one
    env 'frijolero.user', beto

    get '/profile'

    assert_equal %w[0 0 1 0.00], month_row.scan(%r{<td data-label="[^"]+">([^<]*)</td>}).flatten
  end

  def test_the_page_says_so_when_there_is_no_usage
    get '/profile'

    assert_includes last_response.body, 'Todavía no hay llamadas al modelo.'
  end

  def test_rename_saves_the_name_and_empty_is_none
    post '/profile/name', name: '  Ana  '

    assert_equal [303, '/profile'], [last_response.status, URI(last_response.location).path]
    assert_equal 'Ana', Frijolero::Users.find(@owner.id).name

    post '/profile/name', name: ' '

    assert_nil Frijolero::Users.find(@owner.id).name
  end

  def test_the_delete_page_says_what_goes_and_links_the_export
    get "/ledgers/#{@casa.id}/delete"

    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, 'esta es su única copia'
    assert_includes body, %(href="/l/#{@casa.id}/ledger/export")
    assert_includes body, '<form method="post">'
  end

  def test_the_delete_page_names_the_remote_that_stays
    Frijolero::LedgerRepo.for(@casa).git('remote', 'add', 'origin', 'git@github.com:ana/casa.git')

    get "/ledgers/#{@casa.id}/delete"

    assert_includes last_response.body, '<code>git@github.com:ana/casa.git</code> se queda como está'
  end

  def test_delete_with_the_name_deletes_the_ledger_and_its_pdfs
    put_pdf(@casa)

    post "/ledgers/#{@casa.id}/delete", confirm: ' Casa '

    assert_equal [303, '/profile', 'notice=ledger_deleted'],
                 [last_response.status, URI(last_response.location).path, URI(last_response.location).query]
    assert_nil Frijolero::Ledger.find(@casa.id)
    refute_path_exists @casa.dir
    assert_empty @pdfs.list("#{@casa.pdf_prefix}/accounts/AMEX/")
  end

  def test_delete_without_the_name_deletes_nothing
    post "/ledgers/#{@casa.id}/delete", confirm: 'casa'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'escribe el nombre del ledger: Casa'
    assert Frijolero::Ledger.find(@casa.id)
  end

  # A job writes to the bucket and the ledger after its model call.
  def test_delete_waits_for_a_job_in_progress
    Frijolero::App.jobs.push(label: 'AMEX 2610') { nil }

    post "/ledgers/#{@casa.id}/delete", confirm: 'Casa'

    assert_equal 409, last_response.status
    assert_includes last_response.body, 'en curso'
    assert_path_exists @casa.repo_dir
  end

  def test_delete_waits_for_a_classification_in_progress
    pdf = File.join(@casa.dir, 'x.pdf')
    File.write(pdf, 'pdf')
    Frijolero::App.inbox.add(pdf, 'x.pdf')

    post "/ledgers/#{@casa.id}/delete", confirm: 'Casa'

    assert_equal 409, last_response.status
  end

  # The row stays, so a second click finishes the delete.
  def test_a_bucket_failure_says_so_and_keeps_the_ledger
    failing = Object.new
    def failing.delete_prefix(_) = raise(Frijolero::S3::Error, 'S3 DELETE failed (503)')
    Frijolero::App.s3 = failing

    post "/ledgers/#{@casa.id}/delete", confirm: 'Casa'

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'Prueba otra vez'
    assert Frijolero::Ledger.find(@casa.id)
  end

  # The same answer as an unknown id, for the ledger of another user (the admin aside) and,
  # for everyone, the adopted ledger.
  def test_another_users_ledger_and_the_adopted_ledger_are_the_404_of_an_unknown_id
    foreign = Frijolero::Ledger.create(owner_id: user('b@example.com').id, name: 'Ajeno')
    get '/ledgers/nope0000/delete'
    unknown = [last_response.status, last_response.body]

    [[user('c@example.com'), foreign.id, 'Ajeno'], [@owner, 'test', 'Prueba']].each do |actor, id, name|
      env 'frijolero.user', actor
      %i[get post].each do |method|
        send(method, "/ledgers/#{id}/delete", confirm: name)

        assert_equal unknown, [last_response.status, last_response.body], "#{method} #{id}"
      end
    end
    assert_equal 404, unknown.first
    assert Frijolero::Ledger.find(foreign.id)
    assert Frijolero::Ledger.find('test')
  end

  # The admin deletes the ledger of another user from that user's page, and goes back there.
  def test_the_admin_deletes_the_ledger_of_another_user
    beto = user('b@example.com')
    foreign = Frijolero::Ledger.create(owner_id: beto.id, name: 'Ajeno')
    Frijolero::NewLedger.prepare(foreign.repo_dir)

    get "/ledgers/#{foreign.id}/delete"

    assert_includes last_response.body, 'esta es su única copia'
    refute_includes last_response.body, 'ledger/export', 'the admin cannot open the ledger of another user'
    assert_includes last_response.body, %(href="/admin/users/#{beto.id}">Cancelar)

    post "/ledgers/#{foreign.id}/delete", confirm: 'Ajeno'

    assert_equal "/admin/users/#{beto.id}", URI(last_response.location).path
    assert_nil Frijolero::Ledger.find(foreign.id)
  end

  private

  # The row of this month in the history.
  def month_row
    month = "#{Frijolero::Period::MONTHS[Date.today.month - 1].capitalize} #{Date.today.year}"
    last_response.body[%r{<th scope="row">#{month}</th>.*?</tr>}m] || flunk('no row for this month')
  end

  def user(email)
    Frijolero::DB.insert("INSERT INTO users (email, status, created_at) VALUES (?, 'active', ?)", email,
                         Time.now.utc.iso8601)
    Frijolero::Users.find_by_email(email)
  end

  def add_usage(person, at, micros, upload:)
    Frijolero::DB.execute('INSERT INTO usage (user_id, ledger_id, upload, prompt, model, input_tokens, ' \
                          "output_tokens, cost_micros, at) VALUES (?, ?, ?, 'default', 'm', 1, 1, ?, ?)",
                          person.id, @casa.id, upload, micros, at.utc.iso8601)
  end

  def put_pdf(ledger)
    pdf = File.join(ledger.dir, 'in.pdf')
    File.write(pdf, 'pdf')
    @pdfs.put("#{ledger.pdf_prefix}/accounts/AMEX/AMEX 2608.pdf", pdf)
  end
end
