# frozen_string_literal: true

module Frijolero
  # Every request gets the first ledger as its current ledger, until LedgerScope and its
  # /l/<id>/ URLs replace this. Ledger.with puts the previous value back at the end, so a
  # Puma thread never keeps a ledger from one request to the next.
  class OnlyLedger
    def initialize(app)
      @app = app
    end

    def call(env)
      Ledger.with(Ledger.all.first) { @app.call(env) }
    end
  end
end
