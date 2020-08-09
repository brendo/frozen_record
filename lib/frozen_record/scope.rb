# frozen_string_literal: true

module FrozenRecord
  class Scope
    BLACKLISTED_ARRAY_METHODS = [
      :compact!, :flatten!, :reject!, :reverse!, :rotate!, :map!,
      :shuffle!, :slice!, :sort!, :sort_by!, :delete_if,
      :keep_if, :pop, :shift, :delete_at, :compact
    ].to_set

    delegate :first, :last, :length, :collect, :map, :each, :all?, :include?, :to_ary, :to_json, :as_json, :count, to: :to_a
    if defined? ActiveModel::Serializers::Xml
      delegate :to_xml, to: :to_a
    end

    class WhereChain
      def initialize(scope)
        @scope = scope
      end

      def not(criterias)
        @scope.where_not(criterias)
      end
    end

    def initialize(klass)
      @klass = klass
      @where_values = []
      @where_not_values = []
      @order_values = []
      @limit = nil
      @offset = nil
    end

    def find_by_id(id)
      matching_records.find { |r| r.id == id }
    end

    def find(id)
      raise RecordNotFound, "Can't lookup record without ID" unless id
      find_by_id(id) or raise RecordNotFound, "Couldn't find a record with ID = #{id.inspect}"
    end

    def find_by(criterias)
      where(criterias).first
    end

    def find_by!(criterias)
      where(criterias).first!
    end

    def first!
      first or raise RecordNotFound, "No record matched"
    end

    def last!
      last or raise RecordNotFound, "No record matched"
    end

    def to_a
      query_results
    end

    def pluck(*attributes)
      case attributes.length
      when 1
        to_a.map(&attributes.first.to_sym)
      when 0
        raise NotImplementedError, '`.pluck` without arguments is not supported yet'
      else
        to_a.map { |r| attributes.map { |a| r[a] }}
      end
    end

    def ids
      pluck(primary_key)
    end

    def sum(attribute)
      pluck(attribute).sum
    end

    def average(attribute)
      pluck(attribute).sum.to_f / count
    end

    def minimum(attribute)
      pluck(attribute).min
    end

    def maximum(attribute)
      pluck(attribute).max
    end

    def exists?
      !empty?
    end

    def where(criterias = :chain)
      if criterias == :chain
        WhereChain.new(self)
      else
        spawn.where!(criterias)
      end
    end

    def where_not(criterias)
      spawn.where_not!(criterias)
    end

    def order(*ordering)
      spawn.order!(*ordering)
    end

    def limit(amount)
      spawn.limit!(amount)
    end

    def offset(amount)
      spawn.offset!(amount)
    end

    def respond_to_missing?(method_name, *)
      array_delegable?(method_name) || @klass.respond_to?(method_name) || super
    end

    def hash
      comparable_attributes.hash
    end

    def ==(other)
      self.class === other &&
      comparable_attributes == other.comparable_attributes
    end

    protected

    def comparable_attributes
      @comparable_attributes ||= {
        klass: @klass,
        where_values: @where_values.uniq.sort,
        where_not_values: @where_not_values.uniq.sort,
        order_values: @order_values.uniq,
        limit: @limit,
        offset: @offset,
      }
    end

    def scoping
      previous, @klass.current_scope = @klass.current_scope, self
      yield
    ensure
      @klass.current_scope = previous
    end

    def spawn
      clone.clear_cache!
    end

    def clear_cache!
      @comparable_attributes = nil
      @results = nil
      @matches = nil
      self
    end

    def query_results
      slice_records(matching_records)
    end

    def matching_records
      sort_records(select_records(@klass.load_records))
    end

    def select_records(records)
      return records if @where_values.empty? && @where_not_values.empty?

      indices = @klass.index_definitions
      indexed_where_values, unindexed_where_values = @where_values.partition { |criteria| indices.key?(criteria.first) }

      unless indexed_where_values.empty?
        attribute, value = indexed_where_values.shift
        records = indices[attribute].query(value)
        indexed_where_values.each do |(attribute, value)|
          records &= indices[attribute].query(value)
        end
      end

      records.select do |record|
        unindexed_where_values.all? { |attr, value| compare_value(record[attr], value) } &&
        !@where_not_values.any? { |attr, value| compare_value(record[attr], value) }
      end
    end

    def sort_records(records)
      return records if @order_values.empty?

      records.sort do |record_a, record_b|
        compare(record_a, record_b)
      end
    end

    def slice_records(records)
      return records unless @limit || @offset

      first = @offset || 0
      last = first + (@limit || records.length)
      records[first...last] || []
    end

    def compare(record_a, record_b)
      @order_values.each do |attr, order|
        a_value, b_value = record_a.send(attr), record_b.send(attr)
        cmp = a_value <=> b_value
        next if cmp == 0
        return order == :asc ? cmp : -cmp
      end
      0
    end

    def method_missing(method_name, *args, &block)
      if array_delegable?(method_name)
        to_a.public_send(method_name, *args, &block)
      elsif @klass.respond_to?(method_name)
        delegate_to_class(method_name, *args, &block)
      else
        super
      end
    end

    def delegate_to_class(*args, &block)
      scoping { @klass.public_send(*args, &block) }
    end

    def array_delegable?(method)
      Array.method_defined?(method) && BLACKLISTED_ARRAY_METHODS.exclude?(method)
    end

    def where!(criterias)
      @where_values += criterias.map { |k, v| [k.to_s, v] }
      self
    end

    def where_not!(criterias)
      @where_not_values += criterias.map { |k, v| [k.to_s, v] }
      self
    end

    def order!(*ordering)
      @order_values += ordering.map do |order|
        order.respond_to?(:to_a) ? order.to_a : [[order, :asc]]
      end.flatten(1)
      self
    end

    def limit!(amount)
      @limit = amount
      self
    end

    def offset!(amount)
      @offset = amount
      self
    end

    private

    def compare_value(actual, requested)
      return compare_array(actual, requested) if actual.is_a?(Array)
      compare_string(actual, requested)
    end

    def compare_string(actual, requested)
      return actual == requested unless requested.is_a?(Array) || requested.is_a?(Range)
      requested.include?(actual)
    end

    def compare_array(actual, requested)
      return actual.include?(requested) unless requested.is_a?(Array) || requested.is_a?(Range)
      requested.any? { |item| actual.include?(item) }
    end
  end
end
