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
      end

      def run
        UI.title 'Dependencies' do
          require 'yaml'
          UI.puts dependencies.to_yaml

          require 'gviz'
          gviz_id_excluded = /[^0-9A-Za-z]/
          g = Gviz.new
          g.global rankdir: 'LR'
          targets = @podfile.target_definition_list.map{|td| [(td.link_with || ['root']).join(', '), td]}
          targets.each do |link_with, td|
            next if link_with.empty?
            id = :"linkWith#{link_with}"
            g.node id, label: "#{link_with}#{td.exclusive? ? '' : '[+root]'}"
            td.non_inherited_dependencies.each do |d|
                dep_id = :"pod#{d.name.gsub(gviz_id_excluded, '')}"
                g.node dep_id, label: d.name, style: "filled", fillcolor: hexcolor_for(d.name.split('/', 2).first)
                g.edge :"#{id}_#{dep_id}", label: d.requirement
            end
          end
          dependencies.each do |d|
            d = {d => []} if d.kind_of?(String)
            d.each do |parent, children|
              name = parent.split(' ').first
              version = parent.split(' ').last
              dep_id = :"pod#{name.gsub(gviz_id_excluded, '')}"
              g.node dep_id, label: "#{name} #{version}", style: "filled", fillcolor: hexcolor_for(name.split('/', 2).first)
              children.each do |c|
                c_name, c_requirements = c.split(' ', 2)
                c_id = :"pod#{c_name.gsub(gviz_id_excluded, '')}"
                g.edge :"#{dep_id}_#{c_id}", label: c_requirements
              end
            end
          end
          g.save("Podfile.graph", :dot)
          g.save("Podfile.graph", :png)
        end
      end

      def hexcolor_for(string)
        require 'colorable'
        require 'digest/sha1'
        hash = Digest::SHA1.hexdigest(string).hex
        hue = (hash & 0xff) / 255.0 * 359
        sat = ((hash & 0xff00) >> 8) / 255.0 * 50 + 10
        Colorable::Color.new(Colorable::HSB.new(hue.to_i, sat.to_i, 100)).hex
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
          specs = analyzer.analyze(@repo_update || @podspec).specs_by_target.values.flatten(1)
          config.integrate_targets = integrate_targets
          config.skip_repo_update = skip_repo_update

          lockfile = Lockfile.generate(podfile, specs, {})
          pods = lockfile.to_hash['PODS']
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

    end
  end
end
