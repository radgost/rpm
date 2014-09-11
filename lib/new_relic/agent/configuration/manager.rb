# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'forwardable'
require 'new_relic/agent/configuration/mask_defaults'
require 'new_relic/agent/configuration/yaml_source'
require 'new_relic/agent/configuration/default_source'
require 'new_relic/agent/configuration/server_source'
require 'new_relic/agent/configuration/environment_source'
require 'new_relic/agent/configuration/high_security_source'

module NewRelic
  module Agent
    module Configuration
      class Manager
        attr_reader :stripped_exceptions_whitelist

        # Defining these explicitly saves object allocations that we incur
        # if we use Forwardable and def_delegators.
        def [](key)
          @cache[key]
        end

        def has_key?(key)
          @cache.has_key?[key]
        end

        def keys
          @cache.keys
        end

        def initialize
          reset_to_defaults
          @callbacks = Hash.new {|hash,key| hash[key] = [] }

          register_callback(:'strip_exception_messages.whitelist') do |whitelist|
            if whitelist
              @stripped_exceptions_whitelist = parse_constant_list(whitelist).compact
            else
              @stripped_exceptions_whitelist = []
            end
          end
        end

        def add_config_for_testing(source, level=0)
          raise 'Invalid config type for testing' unless [Hash, DottedHash].include?(source.class)
          invoke_callbacks(:add, source)
          @configs_for_testing << [source.freeze, level]
          reset_cache
          log_config(:add, source)
        end

        def remove_config_type(sym)
          source = case sym
          when :high_security then @high_security_source
          when :environment   then @environment_source
          when :server        then @server_source
          when :manual        then @manual_source
          when :yaml          then @yaml_source
          when :default       then @default_source
          end

          remove_config(source)
        end

        def remove_config(source)
          case source
          when HighSecuritySource then @high_security_source = nil
          when EnvironmentSource  then @environment_source   = nil
          when ServerSource       then @server_source        = nil
          when ManualSource       then @manual_source        = nil
          when YamlSource         then @yaml_source          = nil
          when DefaultSource      then @default_source       = nil
          else
            @configs_for_testing.delete_if {|src,lvl| src == source}
          end

          reset_cache
          invoke_callbacks(:remove, source)
          log_config(:remove, source)
        end

        def replace_or_add_config(source)
          source.freeze
          was_finished = finished_configuring?

          invoke_callbacks(:add, source)
          case source
          when HighSecuritySource then @high_security_source = source
          when EnvironmentSource  then @environment_source   = source
          when ServerSource       then @server_source        = source
          when ManualSource       then @manual_source        = source
          when YamlSource         then @yaml_source          = source
          when DefaultSource      then @default_source       = source
          else
            NewRelic::Agent.logger.warn("Invalid config format; config will be ignored: #{source}")
          end

          reset_cache
          log_config(:add, source)

          notify_finished_configuring if !was_finished && finished_configuring?
        end

        def source(key)
          config_stack.each do |config|
            if config.respond_to?(key.to_sym) || config.has_key?(key.to_sym)
              return config
            end
          end
        end

        def fetch(key)
          config_stack.each do |config|
            next unless config
            accessor = key.to_sym

            if config.has_key?(accessor)
              value = evaluate_procs(config[accessor])

              if transform = transform_from_default(accessor)
                return transform.call(value)
              else
                return value
              end
            end
          end

          nil
        end

        def evaluate_procs(value)
          if value.respond_to?(:call)
            instance_eval(&value)
          else
            value
          end
        end

        def transform_from_default(key)
          ::NewRelic::Agent::Configuration::DefaultSource.transform_for(key)
        end

        def register_callback(key, &proc)
          @callbacks[key] << proc
          proc.call(@cache[key])
        end

        def invoke_callbacks(direction, source)
          return unless source
          source.keys.each do |key|

            if @cache[key] != source[key]
              @callbacks[key].each do |proc|
                if direction == :add
                  proc.call(source[key])
                else
                  proc.call(@cache[key])
                end
              end
            end
          end
        end

        def notify_finished_configuring
          NewRelic::Agent.instance.events.notify(:finished_configuring)
        end

        def finished_configuring?
          !@server_source.nil?
        end

        def flattened
          config_stack.reverse.inject({}) do |flat,layer|
            thawed_layer = layer.to_hash.dup
            thawed_layer.each do |k,v|
              begin
                thawed_layer[k] = instance_eval(&v) if v.respond_to?(:call)
              rescue => e
                ::NewRelic::Agent.logger.debug("#{e.class.name} : #{e.message} - when accessing config key #{k}")
                thawed_layer[k] = nil
              end
              thawed_layer.delete(:config)
            end
            flat.merge(thawed_layer.to_hash)
          end
        end

        def apply_mask(hash)
          MASK_DEFAULTS. \
            select {|_, proc| proc.call}. \
            each {|key, _| hash.delete(key) }
          hash
        end

        def to_collector_hash
          DottedHash.new(apply_mask(flattened)).to_hash.delete_if do |k, v|
            default = DEFAULTS[k]
            if default
              default[:local_only]
            else
              # In our tests, we add totally bogus configs, because testing.
              # In those cases, there will be no default. So we'll just let
              # them through.
              false
            end
          end
        end

        def app_names
          case NewRelic::Agent.config[:app_name]
          when Array then NewRelic::Agent.config[:app_name]
          when String then NewRelic::Agent.config[:app_name].split(';')
          else []
          end
        end

        MALFORMED_LABELS_WARNING = "Skipping malformed labels configuration"
        PARSING_LABELS_FAILURE   = "Failure during parsing labels. Ignoring and carrying on with connect."

        MAX_LABEL_COUNT  = 64
        MAX_LABEL_LENGTH = 255

        def parsed_labels
          case NewRelic::Agent.config[:labels]
          when String
            parse_labels_from_string
          else
            parse_labels_from_dictionary
          end
        rescue => e
          NewRelic::Agent.logger.error(PARSING_LABELS_FAILURE, e)
          []
        end

        def parse_labels_from_string
          labels = NewRelic::Agent.config[:labels]
          label_pairs = break_label_string_into_pairs(labels)
          make_label_hash(label_pairs, labels)
        end

        def break_label_string_into_pairs(labels)
          # Strip whitespaces immediately before and after colons or semicolons
          stripped_labels = labels.gsub(/\s*(:|;)\s*/, '\1')
          stripped_labels.split(';').map do |pair|
            pair.split(':')
          end
        end

        def valid_label_pairs?(label_pairs)
          label_pairs.all? do |pair|
            pair.length == 2 &&
              valid_label_item?(pair.first) &&
              valid_label_item?(pair.last)
          end
        end

        def valid_label_item?(item)
          case item
          when String  then !item.empty?
          when Numeric then true
          when true    then true
          when false   then true
          else false
          end
        end

        def make_label_hash(pairs, labels = nil)
          # This can accept a hash, so force it down to an array of pairs first
          pairs = Array(pairs)

          unless valid_label_pairs?(pairs)
            NewRelic::Agent.logger.warn("#{MALFORMED_LABELS_WARNING}: #{labels||pairs}")
            return []
          end

          pairs = limit_number_of_labels(pairs)
          pairs.map do |key, value|
            {
              'label_type'  => truncate(key),
              'label_value' => truncate(value.to_s, key)
            }
          end
        end

        def truncate(text, key=nil)
          if text.length > MAX_LABEL_LENGTH
            if key
              msg = "The value for the label '#{key}' is longer than the allowed #{MAX_LABEL_LENGTH} and will be truncated. Value = '#{text}'"
            else
              msg = "Label name longer than the allowed #{MAX_LABEL_LENGTH} will be truncated. Name = '#{text}'"
            end
            NewRelic::Agent.logger.warn(msg)
            text[0..MAX_LABEL_LENGTH-1]
          else
            text
          end
        end

        def limit_number_of_labels(pairs)
          if pairs.length > MAX_LABEL_COUNT
            NewRelic::Agent.logger.warn("Too many labels defined. Only taking first #{MAX_LABEL_COUNT}")
            pairs[0...64]
          else
            pairs
          end
        end

        def parse_labels_from_dictionary
          make_label_hash(NewRelic::Agent.config[:labels])
        end

        # Generally only useful during initial construction and tests
        def reset_to_defaults
          @high_security_source = nil
          @environment_source   = EnvironmentSource.new
          @server_source        = nil
          @manual_source        = nil
          @yaml_source          = nil
          @default_source       = DefaultSource.new

          @configs_for_testing  = []

          reset_cache
        end

        def reset_cache
          @cache = Hash.new {|hash,key| hash[key] = self.fetch(key) }
        end

        def log_config(direction, source)
          # Just generating this log message (specifically calling
          # flattened.inspect) is expensive enough that we don't want to do it
          # unless we're actually going to be logging the message based on our
          # current log level.
          ::NewRelic::Agent.logger.debug do
            "Updating config (#{direction}) from #{source.class}. Results: #{flattened.inspect}"
          end
        end

        def delete_all_configs_for_testing
          @high_security_source = nil
          @environment_source   = nil
          @server_source        = nil
          @manual_source        = nil
          @yaml_source          = nil
          @default_source       = nil
          @configs_for_testing  = []
        end

        def num_configs_for_testing
          config_stack.size
        end

        def config_classes_for_testing
          config_stack.map(&:class)
        end

        private

        def config_stack
          stack = [@high_security_source,
                   @environment_source,
                   @server_source,
                   @manual_source,
                   @yaml_source,
                   @default_source]

          stack.compact!

          @configs_for_testing.each do |config, at_start|
            if at_start
              stack.insert(0, config)
            else
              stack.push(config)
            end
          end

          stack
        end

        def parse_constant_list(list)
          list.split(/\s*,\s*/).map do |class_name|
            const = constantize(class_name)

            unless const
              NewRelic::Agent.logger.warn "Configuration referenced undefined constant: #{class_name}"
            end

            const
          end
        end

        def constantize(class_name)
          namespaces = class_name.split('::')

          namespaces.inject(Object) do |namespace, name|
            return unless namespace
            namespace.const_get(name) if namespace.const_defined?(name)
          end
        end
      end
    end
  end
end
