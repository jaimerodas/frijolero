# frozen_string_literal: true

module Frijolero
  # Between Login and App. Each ledger page is under /l/<id>/: LedgerScope checks that
  # the signed-in user owns that ledger, makes it the current ledger, and calls App with
  # /l/<id> moved into SCRIPT_NAME, so App's routes keep their plain paths. Ledger.with
  # puts the previous ledger back at the end, so a Puma thread never keeps a ledger from
  # one request to the next.
  class LedgerScope
    # Ledger.new_id makes each id from [a-z0-9].
    IN_LEDGER = %r{\A/l/([a-z0-9]+)(/.*)?\z}

    def initialize(app)
      @app = app
    end

    def call(env)
      path = env['PATH_INFO']
      if path.start_with?('/api/')
        # ponytail: every upload goes to the first ledger; in 4C the API token names its ledger.
        Ledger.with(Ledger.all.first) { @app.call(env) }
      elsif path == '/l' || path.start_with?('/l/')
        in_ledger(env, path)
      else
        bookmark(env, path)
      end
    end

    private

    # An unknown id and another user's ledger get the same answer, so a guess learns
    # nothing. App gets a copy of env: Login holds the original. The path is binary, and
    # SQLite compares a binary string as a BLOB, which matches no id: hence the encode.
    def in_ledger(env, path)
      id, rest = IN_LEDGER.match(path)&.captures
      ledger = id && Ledger.find(id.encode(Encoding::UTF_8))
      return not_found unless ledger && ledger.owner_id == env['frijolero.user']&.id

      env = env.merge('SCRIPT_NAME' => "#{env['SCRIPT_NAME']}/l/#{id}", 'PATH_INFO' => rest || '/')
      Ledger.with(ledger) { @app.call(env) }
    end

    # / and the paths from before /l/<id>/ go to the user's first ledger. Only a GET goes:
    # once a user has several ledgers, a stale form must not post to the wrong one.
    def bookmark(env, path)
      return not_found unless %w[GET HEAD].include?(env['REQUEST_METHOD'])

      ledger = Ledger.owned_by(env['frijolero.user']&.id).first
      if ledger
        query = "?#{env['QUERY_STRING']}" unless env['QUERY_STRING'].to_s.empty?
        [302, { 'location' => "#{env['SCRIPT_NAME']}/l/#{ledger.id}#{path}#{query}" }, []]
      elsif path == '/'
        # ponytail: 4B puts the new-ledger page here, and the list for a user with several ledgers.
        [200, { 'content-type' => 'text/plain; charset=utf-8' }, ['Todavía no tienes un ledger.']]
      else
        not_found
      end
    end

    def not_found = [404, { 'content-type' => 'text/plain; charset=utf-8' }, ['No existe esa página.']]
  end
end
