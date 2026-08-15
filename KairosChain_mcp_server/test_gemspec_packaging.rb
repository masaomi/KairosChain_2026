# frozen_string_literal: true

require 'minitest/autorun'
require 'rubygems'

# Packaging claims, checked against the filesystem rather than against the
# gemspec's own text.
#
# Three defects reached a published release before this file existed, all of the
# same shape — the gemspec asserted something nobody had compared to disk:
#
#   - kairos-plugin-project was shipped by the bin/* glob but missing from
#     spec.executables, so the two hooks calling it failed with "command not
#     found" on every fire, silently. kairos-chain-daemon was missing the same
#     way and was found by a reviewer, not here.
#   - LICENSE was listed in spec.files and did not exist under the build root,
#     so the published package declared MIT and carried no license text.
#   - changelog_uri pointed at a repository-root CHANGELOG.md that does not
#     exist; the tracked one is under this directory.
class TestGemspecPackaging < Minitest::Test
  ROOT = __dir__
  REPO_ROOT = File.expand_path('..', ROOT)

  def spec
    @spec ||= Gem::Specification.load(File.join(ROOT, 'kairos-chain.gemspec'))
  end

  # An entry point an operator or a hook invokes by name has to be on PATH after
  # install, and only spec.executables puts it there. The bin/* glob ships the
  # file either way, which is what makes the omission invisible.
  def test_every_executable_under_bin_is_listed
    on_disk = Dir.glob(File.join(ROOT, 'bin', '*'))
                 .select { |p| File.file?(p) && File.executable?(p) }
                 .map { |p| File.basename(p) }
                 .sort
    refute_empty on_disk, 'bin/ must contain executables'
    missing = on_disk - spec.executables
    assert_empty missing,
                 "shipped by the bin glob but not on PATH after install: #{missing.join(', ')}"
  end

  def test_every_listed_executable_exists_and_can_run
    spec.executables.each do |name|
      path = File.join(ROOT, spec.bindir, name)
      assert File.file?(path), "#{name} is listed but does not exist"
      assert File.executable?(path), "#{name} is listed but is not executable"
      assert_match(/\A#!/, File.read(path, 16).to_s, "#{name} has no shebang")
    end
  end

  # There is deliberately no "every declared file exists" test: spec.files is a
  # Dir[] glob, which only ever yields paths that exist. Such a test cannot
  # fail for any input, and its green presence is what hid that gap.

  def test_the_license_text_ships_and_matches_the_repository
    here = File.join(ROOT, 'LICENSE')
    there = File.join(REPO_ROOT, 'LICENSE')
    assert_includes spec.files, 'LICENSE', 'the license text must ship'
    assert File.file?(here), 'LICENSE must exist under the build root'
    assert_equal File.read(there), File.read(here),
                 'the build-root LICENSE is a copy and has drifted from the repository root'
  end

  # The metadata links are the gem page's only navigation. A path that does not
  # exist in the repository is a dead link on every release.
  def test_the_changelog_link_points_at_a_file_that_exists
    uri = spec.metadata['changelog_uri']
    refute_nil uri, 'changelog_uri must be declared'
    path = uri.sub(%r{\Ahttps://github\.com/[^/]+/[^/]+/blob/[^/]+/}, '')
    assert File.file?(File.join(REPO_ROOT, path)),
           "changelog_uri points at #{path}, which does not exist in the repository"
  end

  # Every require in lib/ that names a gem the standard library no longer
  # carries must be declared, or the boot fails in an isolated install. base64
  # left the default gems in Ruby 3.4 and this floor admits 3.4.
  def test_gems_that_left_the_standard_library_are_declared
    declared = spec.dependencies.map(&:name)
    %w[base64].each do |name|
      used = Dir.glob(File.join(ROOT, 'lib', '**', '*.rb'))
                .any? { |f| File.read(f, encoding: 'UTF-8').match?(/^\s*require ['"]#{name}['"]/) }
      next unless used

      assert_includes declared, name,
                      "lib/ requires #{name}, which is not a default gem on Ruby 3.4+"
    end
  end
end
