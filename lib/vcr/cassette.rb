require 'fileutils'
require 'yaml'
require 'erb'
require 'set'

module VCR
  class Cassette
    class MissingERBVariableError < NameError; end

    VALID_RECORD_MODES = [:all, :none, :new_episodes]

    attr_reader :name, :record_mode, :match_requests_on, :erb, :re_record_interval

    def initialize(name, options = {})
      options = VCR::Config.default_cassette_options.merge(options)
      invalid_options = options.keys - [:record, :erb, :allow_real_http, :match_requests_on, :re_record_interval]

      if invalid_options.size > 0
        raise ArgumentError.new("You passed the following invalid options to VCR::Cassette.new: #{invalid_options.inspect}.")
      end

      @name               = name
      @record_mode        = options[:record]
      @erb                = options[:erb]
      @match_requests_on  = options[:match_requests_on]
      @re_record_interval = options[:re_record_interval]
      @record_mode        = :all if should_re_record?

      deprecate_old_cassette_options(options)
      raise_error_unless_valid_record_mode(record_mode)

      set_http_connections_allowed
      load_recorded_interactions
    end

    def eject
      write_recorded_interactions_to_disk
      VCR.http_stubbing_adapter.restore_stubs_checkpoint(name)
      restore_http_connections_allowed
      restore_ignore_localhost_for_deprecation
    end

    def recorded_interactions
      @recorded_interactions ||= []
    end

    def record_http_interaction(interaction)
      new_recorded_interactions << interaction
    end

    def new_recorded_interactions
      @new_recorded_interactions ||= []
    end

    def file
      File.join(VCR::Config.cassette_library_dir, "#{sanitized_name}.yml") if VCR::Config.cassette_library_dir
    end

    private

    def sanitized_name
      name.to_s.gsub(/[^\w\-\/]+/, '_')
    end

    def raise_error_unless_valid_record_mode(record_mode)
      unless VALID_RECORD_MODES.include?(record_mode)
        raise ArgumentError.new("#{record_mode} is not a valid cassette record mode.  Valid options are: #{VALID_RECORD_MODES.inspect}")
      end
    end

    def should_re_record?
      @re_record_interval &&
      File.exist?(file) &&
      File.stat(file).mtime + @re_record_interval < Time.now &&
      InternetConnection.available?
    end

    def should_allow_http_connections?
      record_mode != :none
    end

    def should_stub_requests?
      record_mode != :all
    end

    def should_remove_matching_existing_interactions?
      record_mode == :all
    end

    def set_http_connections_allowed
      @orig_http_connections_allowed = VCR.http_stubbing_adapter.http_connections_allowed?
      VCR.http_stubbing_adapter.http_connections_allowed = should_allow_http_connections?
    end

    def restore_http_connections_allowed
      VCR.http_stubbing_adapter.http_connections_allowed = @orig_http_connections_allowed
    end

    def load_recorded_interactions
      VCR.http_stubbing_adapter.create_stubs_checkpoint(name)
      if file && File.size?(file)
        begin
          interactions = YAML.load(raw_yaml_content)

          if VCR.http_stubbing_adapter.ignore_localhost?
            interactions.reject! do |i|
              i.uri.is_a?(String) && VCR::LOCALHOST_ALIASES.include?(URI.parse(i.uri).host)
            end
          end

          recorded_interactions.replace(interactions)
        rescue TypeError
          raise unless raw_yaml_content =~ /VCR::RecordedResponse/
          raise "The VCR cassette #{sanitized_name}.yml uses an old format that is now deprecated.  VCR provides a rake task to migrate your old cassettes to the new format.  See http://github.com/myronmarston/vcr/blob/master/CHANGELOG.md for more info."
        end
      end

      if should_stub_requests?
        VCR.http_stubbing_adapter.stub_requests(recorded_interactions, match_requests_on)
      end
    end

    @@struct_cache = Hash.new do |hash, attributes|
      hash[attributes] = Struct.new(*attributes)
    end

    def raw_yaml_content
      content = after_read(File.read(file))
      return content unless @erb

      template = ERB.new(content)

      begin
        return template.result unless @erb.is_a?(Hash)

        # create an object with methods for each desired local variable...
        local_variables = @@struct_cache[@erb.keys].new(*@erb.values)

        # instance_eval seems to be the only way to get the binding for ruby 1.9: http://redmine.ruby-lang.org/issues/show/2161
        template.result(local_variables.instance_eval { binding })
      rescue NameError => e
        example_hash = (@erb.is_a?(Hash) ? @erb : {}).merge(e.name => 'some value')

        raise MissingERBVariableError.new(
          "The ERB in the #{sanitized_name}.yml cassette file references undefined variable #{e.name}.  " +
          "Pass it to the cassette using :erb => #{ example_hash.inspect }."
        )
      end
    end

    def merged_interactions
      old_interactions = recorded_interactions

      if should_remove_matching_existing_interactions?
        match_attributes = match_requests_on

        new_request_matchers = Set.new new_recorded_interactions.map do |i|
          i.request.matcher(match_attributes)
        end

        old_interactions = old_interactions.reject do |i|
          new_request_matchers.include?(i.request.matcher(match_attributes))
        end
      end

      old_interactions + new_recorded_interactions
    end

    def write_recorded_interactions_to_disk
      if VCR::Config.cassette_library_dir && new_recorded_interactions.size > 0
        directory = File.dirname(file)
        FileUtils.mkdir_p directory unless File.exist?(directory)
        File.open(file, 'w') { |f| f.write before_write(merged_interactions.to_yaml) }
      end
    end
    
    def before_write(recordings)
      hook = VCR::Config.before_write_hook      
      hook ? hook[recordings] : recordings
    end
    
    def after_read(recordings)
      hook = VCR::Config.after_read_hook      
      content = hook ? hook[recordings] : recordings
      content
    end
  end
end
