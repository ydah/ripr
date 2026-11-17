# frozen_string_literal: true

require_relative "ripr/version"

module Ripr
  class Error < StandardError; end
  class BaselineFailure < Error; end
end
