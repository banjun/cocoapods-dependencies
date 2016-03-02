module Pod
  class Command
    class Dependencies < Command
      self.summary = "Show project's dependency graph."

      self.description = <<-DESC
        Shows the project's dependency graph.
      DESC

      def self.options
        [
          ['--ignore-lockfile', 'Whether the lockfile should be ignored when calculating the dependency graph'],
          ['--repo-update', 'Fetch external podspecs and run `pod repo update` before calculating the dependency graph'],
          ['--graphviz', 'Outputs the dependency graph in Graphviz format to <podspec name>.gv or Podfile.gv'],
          ['--image', 'Outputs the dependency graph as an image to <podsepc name>.png or Podfile.png'],
        ].concat(super)
      end

      def self.arguments
        [
          CLAide::Argument.new('PODSPEC', false)
        ].concat(super)
      end

      def initialize(argv)
        @podspec_name = argv.shift_argument
        @ignore_lockfile = argv.flag?('ignore-lockfile', false)
        @repo_update = argv.flag?('repo-update', false)
        @produce_graphviz_output = argv.flag?('graphviz', false)
        @produce_image_output = argv.flag?('image', false)
        super
      end

      def validate!
        super
        if @podspec_name
          require 'pathname'
          path = Pathname.new(@podspec_name)
          if path.exist?
            @podspec = Specification.from_file(path)
          else
            @podspec = SourcesManager.
              search(Dependency.new(@podspec_name)).
              specification.
              subspec_by_name(@podspec_name)
          end
        end
        if (@produce_image_output || @produce_graphviz_output) && Executable.which('dot').nil?
          raise Informative, 'GraphViz must be installed and `dot` must be in ' \
            '$PATH to produce image or graphviz output.'
        end
      end

      def run
        require 'yaml'
        graphviz_image_output if @produce_image_output
        graphviz_dot_output if @produce_graphviz_output
        yaml_output
      end

      def dependencies
        @dependencies ||= begin
          analyzer = Installer::Analyzer.new(
            sandbox,
            podfile,
            @ignore_lockfile || @podspec ? nil : config.lockfile
          )

          integrate_targets = config.integrate_targets
          skip_repo_update = config.skip_repo_update?
          config.integrate_targets = false
          config.skip_repo_update = !@repo_update
          analysis = analyzer.analyze(@repo_update || @podspec)
          specs_by_target = analysis.specs_by_target
          config.integrate_targets = integrate_targets
          config.skip_repo_update = skip_repo_update

          deps = specs_by_target.inject({}) do |h, (target, specs)|
            h[target] = specs.inject({}) {|h, spec| h[spec] = spec.all_dependencies; h}
            h
          end
          deps
        end
      end

      def podfile
        @podfile ||= begin
          if podspec = @podspec
            platform = podspec.available_platforms.first
            platform_name, platform_version = platform.name, platform.deployment_target.to_s
            sources = SourcesManager.all.map(&:url)
            Podfile.new do
              sources.each { |s| source s }
              platform platform_name, platform_version
              pod podspec.name, podspec: podspec.defined_in_file
            end
          else
            verify_podfile_exists!
            config.podfile
          end
        end
      end

      def sandbox
        if @podspec
          require 'tmpdir'
          Sandbox.new(Dir.mktmpdir)
        else
          config.sandbox
        end
      end

      def graphviz_data
        @graphviz ||= begin
          require 'graphviz'
          GraphViz::new(output_file_basename, :type => :digraph, :rankdir => 'LR').tap do |graph|
            dependencies.each do |target, spec_to_deps|
              target_node = graphviz_add_node(graph, target)
              target.dependencies.each do |d|
                  graph.add_edge(target_node, d.name, color: 'gray')
              end

              spec_to_deps.each do |spec, deps|
                spec_node = graphviz_add_node(graph, spec)
                deps.each do |d|
                    dep_node = graphviz_add_node(graph, d)
                    graph.add_edge(spec_node, dep_node)
                end
              end
            end
          end
        end
      end

      # Truncates the input string after a pod's name removing version requirements, etc.
      def sanitized_pod_name(name)
        Pod::Dependency.from_string(name).name
      end

      # Returns a Set of Strings of the names of dependencies specified in the Podfile.
      def podfile_dependencies
        Set.new(podfile.target_definitions.values.map { |t| t.dependencies.map { |d| d.name } }.flatten)
      end

      # Returns a [String] of the names of dependencies specified in the podspec.
      def podspec_dependencies
        @podspec.all_dependencies.map { |d| d.name }
      end

      # Returns a [String: [String]] containing resolved mappings from the name of a pod to an array of the names of its dependencies.
      def pod_to_dependencies
        dependencies.map { |d| d.is_a?(Hash) ? d : { d => [] } }.reduce({}) { |combined, individual| combined.merge!(individual) }
      end

      # Basename to use for output files.
      def output_file_basename
        return 'Podfile' unless @podspec_name
        File.basename(@podspec_name, File.extname(@podspec_name))
      end

      def yaml_output
        UI.title 'Dependencies' do
          UI.puts dependencies.to_yaml
        end
      end

      def graphviz_image_output
        graphviz_data.output( :png => "#{output_file_basename}.png")
      end

      def graphviz_dot_output
        graphviz_data.output( :dot => "#{output_file_basename}.gv")
      end

      def graphviz_add_node(graph, object)
        case object.class.to_s
        when 'Pod::Podfile::TargetDefinition'
          graph.add_node(object.name)
        when 'Pod::Specification'
          spec = object
          graph.add_node(spec.name, label: spec.to_s, style: "filled", fillcolor: hexcolor_for_name(spec.root.name))
        when 'Pod::Dependency'
          dep = Pod::Dependency.from_string(object.name)
          graph.add_node(dep.name + dep.specific_version.to_s, style: "filled", fillcolor: hexcolor_for_name(dep.root_name))
        end
      end

      def hexcolor_for_name(string)
        require 'colorable'
        require 'digest/sha1'
        hash = Digest::SHA1.hexdigest(string).hex
        hue = (hash & 0xff) / 255.0 * 359
        sat = ((hash & 0xff00) >> 8) / 255.0 * 50 + 10
        Colorable::Color.new(Colorable::HSB.new(hue.to_i, sat.to_i, 100)).hex
      end
    end
  end
end
