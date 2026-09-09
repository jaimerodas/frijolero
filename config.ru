# frozen_string_literal: true

require_relative 'app/app'
require_relative 'app/login'

Frijolero::App.jobs

map '/up' do
  run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
end

map '/' do
  use Frijolero::Login
  run Frijolero::App
end
