# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

gem "glimmer-dsl-libui" # only needed for the window; the API and tests use stdlib only
gem "win32ole", platforms: :windows # desktop shortcuts (no longer part of stdlib from Ruby 4.0)

group :test do
  gem "minitest"
  gem "rake"
end

group :icon do
  gem "chunky_png" # script/make_icon.rb
end
