# frozen_string_literal: true

require 'logging'

# re-open Ruby logging gem
module Logging
  # the logging gem always sets itself up to initialize little-plugger
  # https://github.com/TwP/logging/commit/5aeeffaaa9fe483c2258a23d3b9e92adfafb3b2e
  class << self
    # little-plugger calls Gem.find_files, incurring an expensive gem scan
    # monkey patch Logging to remove the extended method
    def initialize_plugins; end
  end
end

module Bolt
end
