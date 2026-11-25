# frozen_string_literal: true

module Ripr
  module Engine
    class Mutant < Data.define(:id, :full_id, :site, :subject, :method_hash, :method_start, :method_end, :location, :operator,
                               :replacement, :mode, :original, :mutated, :start_offset, :end_offset, :accepted, :static,
                               :invalid, :invalid_reason, :original_operator, :fixed_operands)
      Location = Data.define(:file, :line, :column, :end_line, :end_column)
      OPTIONAL_FIELDS = { static: nil, invalid: nil, invalid_reason: nil, original_operator: nil, fixed_operands: nil }.freeze
      private_constant :OPTIONAL_FIELDS

      def self.from_analysis(attributes, invalid:)
        location = Location.new(**attributes.fetch(:location).transform_values(&:freeze))
        fields = OPTIONAL_FIELDS.merge(attributes).merge(location: location, invalid: invalid)
        new(**fields.transform_values(&:freeze))
      end

      def to_record
        record = to_h
        OPTIONAL_FIELDS.each_key { |field| record.delete(field) if record[field].nil? }
        record[:location] = location.to_h.transform_keys(&:to_s)
        record.transform_keys(&:to_s)
      end
    end
  end
end
