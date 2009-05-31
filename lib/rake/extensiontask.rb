#!/usr/bin/env ruby

# Define a series of tasks to aid in the compilation of C extensions for
# gem developer/creators.

require 'rake'
require 'rake/clean'
require 'rake/tasklib'
require 'rbconfig'
require 'yaml'

module Rake
  autoload :GemPackageTask, 'rake/gempackagetask'

  class ExtensionTask < TaskLib
    attr_accessor :name
    attr_accessor :gem_spec
    attr_accessor :config_script
    attr_accessor :tmp_dir
    attr_accessor :ext_dir
    attr_accessor :lib_dir
    attr_accessor :platform
    attr_accessor :config_options
    attr_accessor :source_pattern
    attr_accessor :cross_compile
    attr_accessor :cross_platform
    attr_accessor :cross_config_options

    def initialize(name = nil, gem_spec = nil)
      init(name, gem_spec)
      yield self if block_given?
      define
    end

    def init(name = nil, gem_spec = nil)
      @name = name
      @gem_spec = gem_spec
      @config_script = 'extconf.rb'
      @tmp_dir = 'tmp'
      @ext_dir = "ext/#{@name}"
      @lib_dir = 'lib'
      @source_pattern = "*.c"
      @config_options = []
      @cross_compile = false
      @cross_config_options = []
    end

    def platform
      @platform ||= RUBY_PLATFORM
    end

    def cross_platform
      @cross_platform ||= 'i386-mingw32'
    end

    def define
      fail "Extension name must be provided." if @name.nil?

      define_compile_tasks

      # only gems with 'ruby' platforms are allowed to define native tasks
      define_native_tasks if @gem_spec && @gem_spec.platform == 'ruby'

      # only define cross platform functionality when enabled
      return unless @cross_compile

      if cross_platform.is_a?(Array) then
        cross_platform.each { |platf| define_cross_platform_tasks(platf) }
      else
        define_cross_platform_tasks(cross_platform)
      end
    end

    private
    def define_compile_tasks(for_platform = nil, ruby_ver = RUBY_VERSION)
      # platform usage
      platf = for_platform || platform

      # lib_path
      lib_path = lib_dir

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{platf}/#{@name}/#{ruby_ver}"

      # cleanup and clobbering
      CLEAN.include(tmp_path)
      CLOBBER.include("#{lib_path}/#{binary(platf)}")
      CLOBBER.include("#{@tmp_dir}")

      # directories we need
      directory tmp_path
      directory lib_dir

      # copy binary from temporary location to final lib
      # tmp/extension_name/extension_name.{so,bundle} => lib/
      task "copy:#{@name}:#{platf}:#{ruby_ver}" => [lib_path, "#{tmp_path}/#{binary(platf)}"] do
        cp "#{tmp_path}/#{binary(platf)}", "#{lib_path}/#{binary(platf)}"
      end

      # binary in temporary folder depends on makefile and source files
      # tmp/extension_name/extension_name.{so,bundle}
      file "#{tmp_path}/#{binary(platf)}" => ["#{tmp_path}/Makefile"] + source_files do
        chdir tmp_path do
          sh make
        end
      end

      # makefile depends of tmp_dir and config_script
      # tmp/extension_name/Makefile
      file "#{tmp_path}/Makefile" => [tmp_path, extconf] do |t|
        options = @config_options.dup

        # include current directory
        cmd = ['-I.']

        # if fake.rb is present, add to the command line
        if t.prerequisites.include?("#{tmp_path}/fake.rb") then
          cmd << '-rfake'
        end

        # now add the extconf script
        cmd << File.join(Dir.pwd, extconf)

        # rbconfig.rb will be present if we are cross compiling
        if t.prerequisites.include?("#{tmp_path}/rbconfig.rb") then
          options.push(*@cross_config_options)
        end

        # add options to command
        cmd.push(*options)

        chdir tmp_path do
          # FIXME: Rake is broken for multiple arguments system() calls.
          # Add current directory to the search path of Ruby
          # Also, include additional parameters supplied.
          ruby cmd.join(' ')
        end
      end

      # compile tasks
      unless Rake::Task.task_defined?('compile') then
        desc "Compile all the extensions"
        task "compile"
      end

      # compile:name
      unless Rake::Task.task_defined?("compile:#{@name}") then
        desc "Compile #{@name}"
        task "compile:#{@name}"
      end

      # Allow segmented compilation by platform (open door for 'cross compile')
      task "compile:#{@name}:#{platf}" => ["copy:#{@name}:#{platf}:#{ruby_ver}"]
      task "compile:#{platf}" => ["compile:#{@name}:#{platf}"]

      # Only add this extension to the compile chain if current
      # platform matches the indicated one.
      if platf == RUBY_PLATFORM then
        # ensure file is always copied
        file "#{lib_path}/#{binary(platf)}" => ["copy:#{name}:#{platf}:#{ruby_ver}"]

        task "compile:#{@name}" => ["compile:#{@name}:#{platf}"]
        task "compile" => ["compile:#{platf}"]
      end
    end

    def define_native_tasks(for_platform = nil, ruby_ver = RUBY_VERSION)
      platf = for_platform || platform

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{platf}/#{@name}/#{ruby_ver}"

      # lib_path
      lib_path = lib_dir

      # create 'native:gem_name' and chain it to 'native' task
      unless Rake::Task.task_defined?("native:#{@gem_spec.name}:#{platf}")
        task "native:#{@gem_spec.name}:#{platf}" do |t|
          # FIXME: truly duplicate the Gem::Specification
          # workaround the lack of #dup for Gem::Specification
          spec = Gem::Specification.from_yaml(gem_spec.to_yaml)

          # adjust to specified platform
          spec.platform = Gem::Platform.new(platf)

          # clear the extensions defined in the specs
          spec.extensions.clear

          # add the binaries that this task depends on
          # ensure the files get properly copied to lib_dir
          ext_files = t.prerequisites.map { |ext| "#{@lib_dir}/#{File.basename(ext)}" }
          ext_files.each do |ext|
            unless Rake::Task.task_defined?("#{@lib_dir}/#{File.basename(ext)}") then
              # strip out path and .so/.bundle
              file "#{lib_path}/#{File.basename(ext)}" => ["copy:#{File.basename(ext).ext('')}:#{platf}:#{ruby_ver}"]
            end
          end

          # include the files in the gem specification
          spec.files += ext_files

          # Make sure that the required ruby version matches the ruby version
          # we've used for cross compiling:
          target_version = RUBY_VERSION =~ /^1.8/ ? '1.8.6' : '1.9.0'
          spec.required_ruby_version = "~> #{target_version}"

          # Generate a package for this gem
          gem_package = Rake::GemPackageTask.new(spec) do |pkg|
            pkg.need_zip = false
            pkg.need_tar = false
          end

          # ensure the binaries are copied
          task "#{gem_package.package_dir}/#{gem_package.gem_file}" => ["copy:#{@name}:#{platf}:#{ruby_ver}"]
        end
      end

      # add binaries to the dependency chain
      task "native:#{@gem_spec.name}:#{platf}" => ["#{tmp_path}/#{binary(platf)}"]

      # Allow segmented packaging by platfrom (open door for 'cross compile')
      task "native:#{platf}" => ["native:#{@gem_spec.name}:#{platf}"]

      # Only add this extension to the compile chain if current
      # platform matches the indicated one.
      if platf == RUBY_PLATFORM then
        task "native:#{@gem_spec.name}" => ["native:#{@gem_spec.name}:#{platf}"]
        task "native" => ["native:#{platf}"]
      end
    end

    def define_cross_platform_tasks(for_platform)
      if ruby_vers = ENV['RUBY_CC_VERSION']
        ruby_vers = ENV['RUBY_CC_VERSION'].split(File::PATH_SEPARATOR)
      else
        ruby_vers = [RUBY_VERSION]
      end

      ruby_vers.each do |version|
        define_cross_platform_tasks_with_version(for_platform, version)
      end
    end

    def define_cross_platform_tasks_with_version(for_platform, ruby_ver)
      config_path = File.expand_path("~/.rake-compiler/config.yml")

      # warn the user about the need of configuration to use cross compilation.
      unless File.exist?(config_path)
        warn "rake-compiler must be configured first to enable cross-compilation"
        return
      end

      config_file = YAML.load_file(config_path)

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{for_platform}/#{@name}/#{ruby_ver}"

      # lib_path
      lib_path = lib_dir

      unless rbconfig_file = config_file["rbconfig-#{ruby_ver}"] then
        warn "no configuration section for specified version of Ruby (rbconfig-#{ruby_ver})"
        return
      end

      # mkmf
      mkmf_file = File.expand_path(File.join(File.dirname(rbconfig_file), '..', 'mkmf.rb'))

      # define compilation tasks for cross platfrom!
      define_compile_tasks(for_platform, ruby_ver)

      # chain fake.rb, rbconfig.rb and mkmf.rb to Makefile generation
      file "#{tmp_path}/Makefile" => ["#{tmp_path}/fake.rb",
                                      "#{tmp_path}/rbconfig.rb",
                                      "#{tmp_path}/mkmf.rb"]

      # copy the file from the cross-ruby location
      file "#{tmp_path}/rbconfig.rb" => [rbconfig_file] do |t|
        cp t.prerequisites.first, t.name
      end

      # copy mkmf from cross-ruby location
      file "#{tmp_path}/mkmf.rb" => [mkmf_file] do |t|
        cp t.prerequisites.first, t.name
      end

      # genearte fake.rb for different ruby versions
      file "#{tmp_path}/fake.rb" do |t|
        File.open(t.name, 'w') do |f|
          f.write fake_rb(ruby_ver)
        end
      end

      # now define native tasks for cross compiled files
      define_native_tasks(for_platform, ruby_ver) if @gem_spec && @gem_spec.platform == 'ruby'

      # create cross task
      task 'cross' do
        # clear compile dependencies
        Rake::Task['compile'].prerequisites.reject! { |t| !compiles_cross_platform.include?(t) }

        # chain the cross platform ones
        task 'compile' => ["compile:#{for_platform}"]

        # clear lib/binary dependencies and trigger cross platform ones
        # check if lib/binary is defined (damn bundle versus so versus dll)
        if Rake::Task.task_defined?("#{lib_path}/#{binary(for_platform)}") then
          Rake::Task["#{lib_path}/#{binary(for_platform)}"].prerequisites.clear
        end

        # FIXME: targeting multiple platforms copies the file twice
        file "#{@lib_dir}/#{binary(for_platform)}" => ["copy:#{@name}:#{for_platform}:#{ruby_ver}"]

        # if everything for native task is in place
        if @gem_spec && @gem_spec.platform == 'ruby' then
          # double check: only cross platform native tasks should be here
          # FIXME: Sooo brittle
          Rake::Task['native'].prerequisites.reject! { |t| !natives_cross_platform.include?(t) }
          task 'native' => ["native:#{for_platform}"]
        end
      end
    end

    def extconf
      "#{@ext_dir}/#{@config_script}"
    end

    def make
      RUBY_PLATFORM =~ /mswin/ ? 'nmake' : 'make'
    end

    def binary(platform = nil)
      ext = case platform
        when /darwin/
          'bundle'
        when /mingw|mswin|linux/
          'so'
        else
          RbConfig::CONFIG['DLEXT']
      end
      "#{@name}.#{ext}"
    end

    def source_files
     @source_files ||= FileList["#{@ext_dir}/#{@source_pattern}"]
    end

    def compiles_cross_platform
      [*@cross_platform].map { |p| "compile:#{p}" }
    end

    def natives_cross_platform
      [*@cross_platform].map { |p| "native:#{p}" }
    end

    def fake_rb(version)
      <<-FAKE_RB
        class Object
          remove_const :RUBY_PLATFORM
          remove_const :RUBY_VERSION
          RUBY_PLATFORM = "i386-mingw32"
          RUBY_VERSION = "#{version}"
        end
FAKE_RB
    end
  end
end
