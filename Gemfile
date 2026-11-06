# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

# The window. Plain libui bindings, no other gems, so startup loads few files
# (that matters where antivirus scans every file Ruby opens).
gem "libui", "~> 0.1"
gem "win32ole", platforms: :windows # desktop shortcuts (no longer part of stdlib from Ruby 4.0)

group :test do
  gem "minitest"
  gem "rake"
end

group :icon do
  gem "chunky_png" # script/make_icon.rb
end
