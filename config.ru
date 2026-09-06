# frozen_string_literal: true

require_relative 'app/app'

Frijolero::App.jobs

password = ENV.fetch('APP_PASSWORD')

map '/up' do
  run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
end

map '/' do
  use Rack::Auth::Basic, 'Frijolero' do |_user, given|
    Rack::Utils.secure_compare(given, password)
  end
  run Frijolero::App
end
