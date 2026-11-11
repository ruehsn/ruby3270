# frozen_string_literal: true

# Export / Import Settings: what goes in the file and how it merges.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "tmpdir"
require "tn3270"
require "tn3270/gui/settings_transfer"
require "tn3270/gui/spell_words"
require "fileutils"

class SettingsTransferTest < Minitest::Test
  ST = Tn3270::Gui::SettingsTransfer
  Snip = Struct.new(:name, :text)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.remove_entry(@dir)

  def config(name, values = {})
    c = Tn3270::Gui::Config.load(File.join(@dir, name))
    c["personal_spelling"] = File.join(@dir, "#{name}-spelling.txt") # never your real word file
    values.each { |k, v| c[k] = v }
    c
  end

  def test_export_leaves_this_computers_things_behind
    c = config("a.yml", "caps" => true, "recent" => ["PROD"], "engine" => "C:/x/ws3270.exe",
                        "connections" => [{ "name" => "PROD", "host" => "prod", "port" => 23 }])
    path = File.join(@dir, "out.yml")
    ST.write(path, ST.export(c, [Snip.new("Logon", "LOGON{Enter}")]))
    bundle = ST.read(path)
    assert_equal({ "caps" => true }, bundle["options"])
    assert_equal ["PROD"], bundle["connections"].map { |x| x["name"] }
    assert_equal [{ "name" => "Logon", "text" => "LOGON{Enter}" }], bundle["snippets"]
    assert_equal "1 session, 1 snippet and 1 option", ST.summary(bundle)
  end

  def test_import_merges_by_name
    mine = config("b.yml", "keys" => { "F13" => "pf13" },
                           "connections" => [{ "name" => "PROD", "host" => "old", "port" => 23 },
                                             { "name" => "Mine", "host" => "m", "port" => 23 }])
    bundle = { "options" => { "caps" => true, "spell_ignore" => ["TSO"], "keys" => { "F14" => "pf14" },
                              "recent" => ["X"] },
               "connections" => [{ "name" => "prod", "host" => "new", "port" => 992, "tls" => true }],
               "snippets" => [{ "name" => "Logon", "text" => "x" }] }
    Tn3270::Gui::SpellWords.add(mine, ["JCL"])
    path = File.join(@dir, "in.yml")
    File.write(path, bundle.merge(ST::MARK => 1).to_yaml)
    snippets = ST.apply(ST.read(path), mine)
    assert mine["caps"]
    assert_equal %w[jcl tso], Tn3270::Gui::SpellWords.personal(mine) # added to your word file
    assert_nil mine["spell_ignore"]
    assert_equal({ "F13" => "pf13", "F14" => "pf14" }, mine["keys"])
    assert_equal [], mine["recent"] # never imported
    assert_equal [%w[Mine m], %w[prod new]], mine.connections.map { |x| [x["name"], x["host"]] }
    assert_equal 62, mine.connections.last["rows"] # filled in from the defaults
    assert_equal ["Logon"], snippets.map { |s| s["name"] }
  end

  def test_welcome_is_looked_for_outside_the_program_folder_first
    env = { "RUBY3270_WELCOME" => "\\\\server\\team\\welcome.yml", "ProgramData" => "C:/ProgramData" }
    assert_equal ["\\\\server\\team\\welcome.yml", "C:/ProgramData/ruby3270/welcome.yml", "D:/app/welcome.yml"],
                 ST.welcome_paths(env, program_dir: "D:/app")
    assert_equal ["D:/app/welcome.yml"], ST.welcome_paths({}, program_dir: "D:/app")
  end

  def test_welcome_is_imported_on_a_first_launch_only
    require "tn3270/gui/snippet_library"
    welcome = File.join(@dir, "welcome.yml")
    File.write(welcome, { ST::MARK => 1, "options" => { "crosshair" => true },
                          "connections" => [{ "name" => "TEAM", "host" => "t", "port" => 23 }],
                          "snippets" => [{ "name" => "Logon", "text" => "LOGON{Enter}" }] }.to_yaml)
    missing = File.join(@dir, "nope.yml")

    c = config("first.yml", "personal_snippets" => File.join(@dir, "snips.yml"))
    lib = Tn3270::Gui::SnippetLibrary.new(c)
    assert_nil ST.welcome(c, lib, first: false, paths: [welcome]) # not a first launch
    assert_equal welcome, ST.welcome(c, lib, first: true, paths: [missing, welcome])
    assert c["crosshair"]
    assert_equal ["TEAM"], c.connections.map { |x| x["name"] } # replaces the built-in demo session
    assert_equal welcome, Tn3270::Gui::Config.load(c.path)["welcome_imported"] # saved
    lib.reload_if_changed
    assert_equal ["Logon"], lib.items.map(&:name)

    File.write(welcome, "not: [a settings file")
    assert_nil ST.welcome(config("x.yml"), lib, first: true, paths: [welcome]) # broken: skipped
  end

  def test_rejects_other_files
    path = File.join(@dir, "other.yml")
    File.write(path, { "name" => "x" }.to_yaml)
    assert_raises(ArgumentError) { ST.read(path) }
    File.write(path, { ST::MARK => 99 }.to_yaml)
    assert_raises(ArgumentError) { ST.read(path) }
  end
end

class SpellWordsTest < Minitest::Test
  W = Tn3270::Gui::SpellWords

  def test_built_in_site_and_team_lists_add_up
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "data", "ruby3270"))
      File.write(File.join(dir, "data", "ruby3270", "spelling.txt"), "# company words\nACMEPLEX  zorbo\n\n")
      File.write(File.join(dir, "team.txt"), "Frobnitz\n")
      config = { "spell_word_files" => [File.join(dir, "team.txt"), File.join(dir, "missing.txt")] }
      words = W.load(config, env: { "ProgramData" => File.join(dir, "data") }, program_dir: dir)
      assert_includes words, "jcl"       # built in
      assert_includes words, "msgclass"
      assert_includes words, "acmeplex"  # %ProgramData%\ruby3270\spelling.txt
      assert_includes words, "zorbo"
      assert_includes words, "frobnitz"  # a team file
      refute_includes words, "#"
    end
  end

  def test_your_words_are_their_own_file
    Dir.mktmpdir do |dir|
      file = File.join(dir, "mine.txt")
      config = Tn3270::Gui::Config.load(File.join(dir, "settings.yml"))
      config["personal_spelling"] = file
      assert_equal %w[zorbo], W.add(config, %w[Zorbo zorbo])
      assert_equal [], W.add(config, ["ZORBO"]) # already there
      File.write(file, File.read(file) + "frobnitz") # edited by hand, no newline at the end
      W.add(config, ["Blarg"])
      assert_equal %w[zorbo frobnitz blarg], W.personal(config)
      assert File.read(file).start_with?("# Your words"), "made with a comment saying what it is"
      assert_includes W.load(config, env: {}, program_dir: dir), "blarg"
    end
  end

  def test_old_settings_list_moves_to_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.yml")
      File.write(path, { "spell_ignore" => %w[ACMEPLEX zorbo], "personal_spelling" => File.join(dir, "w.txt") }.to_yaml)
      config = Tn3270::Gui::Config.load(path)
      W.migrate(config)
      assert_equal %w[acmeplex zorbo], W.personal(config)
      refute YAML.safe_load_file(path).key?("spell_ignore"), "taken out of the settings"
    end
  end

  def test_export_carries_your_words
    Dir.mktmpdir do |dir|
      config = Tn3270::Gui::Config.load(File.join(dir, "settings.yml"))
      config["personal_spelling"] = File.join(dir, "w.txt")
      W.add(config, %w[zorbo])
      assert_equal %w[zorbo], Tn3270::Gui::SettingsTransfer.export(config, [])["options"]["spell_ignore"]
    end
  end

  def test_a_changed_file_changes_the_stamp
    Dir.mktmpdir do |dir|
      config = { "personal_spelling" => File.join(dir, "w.txt") }
      before = W.stamp(config, env: {}, program_dir: dir)
      W.add(config, %w[zorbo])
      refute_equal before, W.stamp(config, env: {}, program_dir: dir)
    end
  end
end
