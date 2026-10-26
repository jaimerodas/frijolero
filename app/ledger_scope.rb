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

    # The one 404 of the pages outside App: Admin and Ledgers answer with it too, so a
    # page that exists for another user looks like one that does not exist at all.
    def self.not_found = [404, { 'content-type' => 'text/plain; charset=utf-8' }, ['No existe esa página.']]

    def initialize(app)
      @app = app
    end

    def call(env)
      path = env['PATH_INFO']
      if path.start_with?('/api/')
        # Login put the ledger of the bearer token in env.
        ledger = Ledger.find(env['frijolero.api_ledger'].to_s)
        ledger ? Ledger.with(ledger) { @app.call(env) } : not_found
      elsif path == '/l' || path.start_with?('/l/')
        in_ledger(env, path)
      else
        bookmark(env, path)
      end
    end

    private

    # An unknown id and another user's ledger get the same answer, so a guess learns
    # nothing. App gets a copy of env: Login holds the original.
    def in_ledger(env, path)
      id, rest = IN_LEDGER.match(path)&.captures
      ledger = owned_ledger(env, id)
      return not_found unless ledger
      # An own repo that is not cloned yet has no pages: its connect page finishes it.
      return redirect(env, "/ledgers/#{id}/connect") unless File.directory?(ledger.repo_dir)

      env = env.merge('SCRIPT_NAME' => "#{env['SCRIPT_NAME']}/l/#{id}", 'PATH_INFO' => rest || '/')
      Ledger.with(ledger) { @app.call(env) }
    end

    # The path is binary, and SQLite compares a binary string as a BLOB, which matches no
    # id: hence the encode.
    def owned_ledger(env, id)
      ledger = id && Ledger.find(id.encode(Encoding::UTF_8))
      ledger if ledger && ledger.owner_id == env['frijolero.user']&.id
    end

    # The paths from before /l/<id>/ go to the user's first ledger (Ledgers owns /). Only a
    # GET goes: once a user has several ledgers, a stale form must not post to the wrong one.
    def bookmark(env, path)
      ledger = Ledger.owned_by(env['frijolero.user']&.id).first
      return not_found unless ledger && %w[GET HEAD].include?(env['REQUEST_METHOD'])

      query = "?#{env['QUERY_STRING']}" unless env['QUERY_STRING'].to_s.empty?
      redirect(env, "/l/#{ledger.id}#{path}#{query}")
    end

    def redirect(env, path) = [302, { 'location' => "#{env['SCRIPT_NAME']}#{path}" }, []]

    def not_found = self.class.not_found
  end
end
