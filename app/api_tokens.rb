# frozen_string_literal: true

module Frijolero
  # /tokens: the API tokens of the current ledger. The iOS Shortcut sends one, and its
  # uploads go to this ledger. A new token shows once, in the answer to its POST: never
  # in a redirect, a log or the database.
  class App
    get('/tokens') { tokens_page }

    post '/tokens' do
      name = params['name'].to_s.strip
      halt 422, 'Ponle un nombre al token' if name.empty?

      cache_control :no_store
      tokens_page(new_token: ApiTokens.create(Ledger.current.id, name))
    end

    post '/tokens/revoke' do
      ApiTokens.revoke(Ledger.current.id, params['token'].to_s)
      redirect '/tokens', 303
    end

    helpers do
      def tokens_page(new_token: nil)
        erb :tokens, locals: { tokens: ApiTokens.for_ledger(Ledger.current.id), new_token: new_token }
      end
    end
  end
end
