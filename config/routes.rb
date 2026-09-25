# frozen_string_literal: true

Belt.application.routes.draw do
  namespace :s3arch, auth: :cognito, tables: [:search_indexes] do
    get '/', action: 'index'
    post '/rebuild', action: 'rebuild'
  end
end
