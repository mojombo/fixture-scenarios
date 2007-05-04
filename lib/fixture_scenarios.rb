# FixtureScenarios

class Class
  private
    
    # Rails' class inheritable accessors are all broken due to a bad inherit implementation.
    # This method will override the bad one with one that actually works.
    def inherited_with_inheritable_attributes(child)
      inherited_without_inheritable_attributes(child) if respond_to?(:inherited_without_inheritable_attributes)
      
      new_inheritable_attributes = {}
      inheritable_attributes.each do |key, value|
        new_inheritable_attributes[key] = value.dup rescue value
      end
      
      child.instance_variable_set('@inheritable_attributes', new_inheritable_attributes)
    end
    
    alias inherited inherited_with_inheritable_attributes
end

class Fixtures < YAML::Omap
  def self.create_fixtures(fixtures_directory, table_names, file_names = {}, ruby_files = [], class_names = {})
    table_names = [table_names].flatten.map { |n| n.to_s }
    connection = block_given? ? yield : ActiveRecord::Base.connection
    ActiveRecord::Base.silence do
      fixtures_map = {}
      fixtures = table_names.map do |table_name|
        fixtures_map[table_name] = Fixtures.new(connection, File.split(table_name.to_s).last, class_names[table_name.to_sym], file_names[table_name] || [File.join(fixtures_directory, table_name.to_s)])
      end
      all_loaded_fixtures.merge! fixtures_map
      
      connection.transaction(Thread.current['open_transactions'] == 0) do
        fixtures.reverse.each { |fixture| fixture.delete_existing_fixtures }
        fixtures.each { |fixture| fixture.insert_fixtures }
        
        ruby_files.each { |ruby_file| require ruby_file }

        # Cap primary key sequences to max(pk).
        if connection.respond_to?(:reset_pk_sequence!)
          table_names.each do |table_name|
            connection.reset_pk_sequence!(table_name)
          end
        end
      end

      return fixtures.size > 1 ? fixtures : fixtures.first
    end
  end
  
  def self.destroy_fixtures(table_names)
    table_names = [table_names].flatten.map { |n| n.to_s }
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.silence do
      table_names.each do |table_name|
        connection.delete "DELETE FROM #{table_name}", 'Fixture Delete'
      end
    end
  end
  
  def initialize(connection, table_name, class_name, fixture_paths, file_filter = DEFAULT_FILTER_RE)
    @connection, @table_name, @fixture_paths, @file_filter = connection, table_name, fixture_paths, file_filter
    @class_name = class_name || 
                  (ActiveRecord::Base.pluralize_table_names ? @table_name.split('.').last.singularize.camelize : @table_name.split('.').last.camelize)
    @table_name = ActiveRecord::Base.table_name_prefix + @table_name + ActiveRecord::Base.table_name_suffix
    read_fixture_files
  end
  
  private

    def read_fixture_files
      if yaml_content?
        # YAML fixtures
        begin
          yaml_string = ""
          @fixture_paths.each do |fixture_path|
            Dir["#{yaml_file_path(fixture_path)}/**/*.yml"].select {|f| test(?f,f) }.each do |subfixture_path|
              yaml_string << IO.read(subfixture_path)
            end
            yaml_string << IO.read(yaml_file_path(fixture_path)) << "\n"
          end

          if yaml = YAML::load(erb_render(yaml_string))
            yaml = yaml.value if yaml.respond_to?(:type_id) and yaml.respond_to?(:value)
            yaml.each do |name, data|
              self[name] = Fixture.new(data, @class_name)
            end
          end
        rescue Exception=>boom
          raise Fixture::FormatError, "a YAML error occurred parsing one of #{(@fixture_paths.map { |o| yaml_file_path(o) }).inspect}. Please note that YAML must be consistently indented using spaces. Tabs are not allowed. Please have a look at http://www.yaml.org/faq.html\nThe exact error was:\n  #{boom.class}: #{boom}"
        end
      elsif csv_content?
        # CSV fixtures
        @fixture_paths.each do |fixture_path|
          reader = CSV::Reader.create(erb_render(IO.read(csv_file_path(fixture_path))))
          header = reader.shift
          i = 0
          reader.each do |row|
            data = {}
            row.each_with_index { |cell, j| data[header[j].to_s.strip] = cell.to_s.strip }
            self["#{Inflector::underscore(@class_name)}_#{i+=1}"]= Fixture.new(data, @class_name)
          end
        end
      elsif deprecated_yaml_content?
        raise Fixture::FormatError, ".yml extension required for all files."
      else
        # Standard fixtures
        Dir.entries(@fixture_path).each do |file|
          path = File.join(@fixture_path, file)
          if File.file?(path) and file !~ @file_filter
            self[file] = Fixture.new(path, @class_name)
          end
        end
      end
    end
    
    def yaml_content?
      File.file?(@fixture_paths.first + ".yml") ||
      File.file?(@fixture_paths.first)
    end

    def yaml_file_path(file)
      file =~ /\.yml$/ ? file : "#{file}.yml"
    end
    
    def deprecated_yaml_content?
      File.file?(@fixture_paths.first + ".yaml") ||
      File.file?(@fixture_paths.first)
    end

    def deprecated_yaml_file_path
      "#{@fixture_path}.yaml"
    end

    def csv_content?
      File.file?(@fixture_paths.first + ".csv") ||
      File.file?(@fixture_paths.first)
    end
    
    def csv_file_path(file)
      file =~ /\.csv$/ ? file : "#{file}.csv"
    end
end

module Test
  module Unit
    class TestSuite
      
      def run_with_finish(result, &progress_block)
        run_without_finish(result, &progress_block)
        name.constantize.finish rescue nil
      end
      
      alias run_without_finish run
      alias run run_with_finish
      
    end
  end
end

module Test #:nodoc:
  module Unit #:nodoc:
    class TestCase #:nodoc:
      class_inheritable_accessor :fixture_file_names
      class_inheritable_accessor :ruby_file_names
      
      class_inheritable_accessor :scenarios_load_root_fixtures
      
      self.ruby_file_names = []
      self.fixture_file_names = {}
      
      self.scenarios_load_root_fixtures = true
      
      def self.finish
        Fixtures.destroy_fixtures(fixture_table_names)
      end
      
      def self.fixtures(*table_names)
        table_names = table_names.flatten.map { |n| n.to_s }
        
        table_names.each do |table_name|
          self.fixture_file_names[table_name] ||= []
          self.fixture_file_names[table_name] << "#{self.fixture_path}#{table_name}.yml"
        end
        
        self.fixture_table_names |= table_names
        require_fixture_classes(table_names)
        setup_fixture_accessors(table_names)
      end
      
      def self.scenario(scenario_name = nil, options = {})
        # handle options
        defaults = {:root => self.scenarios_load_root_fixtures}
        options = defaults.merge(options)
        
        # find the scenario directory
        scenario_path = Dir.glob("#{self.fixture_path}**/*").grep(Regexp.new("/#{scenario_name}$")).first
        scenario_path = scenario_path[self.fixture_path.length..scenario_path.length]
        scenario_dirs = scenario_path.split('/').unshift('')

        # collect the file paths from which to load
        scenario_paths = []
        while !scenario_dirs.empty?
          unless !options[:root] && scenario_dirs.size == 1
            scenario_paths << self.fixture_path.chop + scenario_dirs.join('/')
          end
          scenario_dirs.pop
        end
        scenario_paths.reverse!
                
        # collect the list of yaml and ruby files
        yaml_files = []
        ruby_files = []
        scenario_paths.each do |path|
          yaml_files |= Dir.glob("#{path}/*.y{am,m}l")
          ruby_files |= Dir.glob("#{path}/*.rb")
        end
                
        # collect table names
        table_names = []
        yaml_files.each do |file_path|
          file_name = file_path.split("/").last
          table_name = file_name[0..file_name.rindex('.') - 1]
          table_names << table_name
          self.fixture_file_names[table_name] ||= []
          self.fixture_file_names[table_name] << file_path
        end
        
        # collect ruby files
        self.ruby_file_names |= ruby_files
                
        self.fixture_table_names |= table_names
        
        require_fixture_classes(table_names)
        setup_fixture_accessors(table_names)
      end
      
      def self.setup_fixture_accessors(table_names=nil)
        (table_names || fixture_table_names).each do |table_name|
          table_name = table_name.split('.').last
          define_method(table_name) do |fixture, *optionals|
            force_reload = optionals.shift
            @fixture_cache[table_name] ||= Hash.new
            @fixture_cache[table_name][fixture] = nil if force_reload
            if @loaded_fixtures[table_name][fixture.to_s]
              @fixture_cache[table_name][fixture] ||= @loaded_fixtures[table_name][fixture.to_s].find
            else
              raise StandardError, "No fixture with name '#{fixture}' found for table '#{table_name}'"
            end
          end
        end
      end
      
      private
        def load_fixtures
          @loaded_fixtures = {}
          fixtures = Fixtures.create_fixtures(fixture_path, fixture_table_names, fixture_file_names, ruby_file_names, fixture_class_names)
          unless fixtures.nil?
            if fixtures.instance_of?(Fixtures)
              @loaded_fixtures[fixtures.table_name.split('.').last] = fixtures
            else
              fixtures.each { |f| @loaded_fixtures[f.table_name.split('.').last] = f }
            end
          end
        end
    end
  end
end