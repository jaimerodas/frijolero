# frozen_string_literal: true

require_relative 'app/app'
require_relative 'app/login'
require_relative 'app/ledger_scope'

# The database, the first admin, and the ledger of the single-user layout, moved once.
Frijolero::Migration.run
# Each ledger's job log marks the jobs that a restart cut short, and its Bandeja takes
# back the uploads that have no answer yet.
Frijolero::Ledger.all.each do |ledger|
  Frijolero::Ledger.with(ledger) do
    Frijolero::App.jobs
    Frijolero::App.inbox_worker
  end
end

map '/up' do
  run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
end

# Login first: the sign-in pages run with no current ledger. LedgerScope then gives
# each request the ledger of its /l/<id>/ path.
map '/' do
  use Frijolero::Login
  use Frijolero::LedgerScope
  run Frijolero::App
end
