# frozen_string_literal: true

require_relative 'app/app'
require_relative 'app/login'
require_relative 'app/only_ledger'

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

map '/' do
  use Frijolero::OnlyLedger
  use Frijolero::Login
  run Frijolero::App
end
