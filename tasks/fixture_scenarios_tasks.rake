namespace :test do
  desc "Run the scenario tests in test/scenarios"
  Rake::TestTask.new(:scenarios => "db:test:prepare") do |t|
    t.libs << "test"
    t.pattern = 'test/scenario/**/*_test.rb'
    t.verbose = true
  end
end

desc 'Test all scenarios'
task :test do
  Rake::Task["test:scenarios"].invoke   rescue got_error = true
end

namespace :db do
  namespace :fixtures do
    task :load => :environment do
      require 'active_record/fixtures'
      ActiveRecord::Base.establish_connection(RAILS_ENV.to_sym)
      fixture_files = ENV['FIXTURES'] ? ENV['FIXTURES'].split(/,/) : Dir.glob(File.join(RAILS_ROOT, 'test', 'fixtures', '*.{yml,csv}'))
      fixture_files.map! { |file| File.basename(file, '.*') }
      Fixtures.create_fixtures('test/fixtures', fixture_files)
     end
  end
  
  namespace :scenario do
    desc 'Load the given scenario into the database. Requires SCENARIO=x. Specify ROOT=false to not load root fixtures.'
    task :load => :environment do
      require 'active_record/fixtures'
      require 'fixture_scenarios'
      ActiveRecord::Base.establish_connection(RAILS_ENV.to_sym)
      
      fixture_path = RAILS_ROOT + '/test/fixtures/'
      scenario_name = ENV['SCENARIO']
      root = ENV['ROOT'] == 'false' ? false : true
      
      # find the scenario directory
      scenario_path = Dir.glob("#{fixture_path}**/*").grep(Regexp.new("/#{scenario_name}$")).first
      scenario_path = scenario_path[fixture_path.length..scenario_path.length]
      scenario_dirs = scenario_path.split('/').unshift('')
      
      # collect the file paths from which to load
      scenario_paths = []
      while !scenario_dirs.empty?
        unless !root && scenario_dirs.size == 1
          scenario_paths << fixture_path.chop + scenario_dirs.join('/')
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
            
      fixture_file_names = {}
      ruby_file_names = []
      fixture_table_names = []
      fixture_class_names = {}
              
      # collect table names
      table_names = []
      yaml_files.each do |file_path|
        file_name = file_path.split("/").last
        table_name = file_name[0..file_name.rindex('.') - 1]
        table_names << table_name
        fixture_file_names[table_name] ||= []
        fixture_file_names[table_name] << file_path
      end
      
      # collect ruby files
      ruby_file_names |= ruby_files

      fixture_table_names |= table_names
      
      Fixtures.create_fixtures(fixture_path, fixture_table_names, fixture_file_names, ruby_file_names, fixture_class_names)
      
      # (ENV['SCENARIO'] ? ENV['SCENARIO'].split(/,/) : Dir.glob(File.join(RAILS_ROOT, 'test', 'fixtures', '*.{yml,csv}'))).each do |fixture_file|
      #   Fixtures.create_fixtures('test/fixtures', File.basename(fixture_file, '.*'))
    end
  end
end