# frozen_string_literal: true

require 'sinatra/base'
require_relative 'ledger_scope'

module Frijolero
  # The pages outside any ledger: Ledgers (/ and /ledgers/…), Admin (/admin/…) and
  # PasskeysPage (/passkeys…). Each is a middleware between Login and LedgerScope, and
  # passes every other path down. They have no current ledger, so they must not read one:
  # a page here names its ledger by id and checks its owner. Their header is _bar.erb.
  # Login has already put the user in env.
  class Page < Sinatra::Base
    set :views, App.views

    helpers LocalTime
    helpers do
      def user = env['frijolero.user']

      def h(text) = Rack::Utils.escape_html(text.to_s)

      def head(title) = erb(:_head, layout: false, locals: { title: title, refresh: nil })

      def bar = erb(:_bar, layout: false)
    end
  end
end
