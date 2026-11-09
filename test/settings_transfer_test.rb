# frozen_string_literal: true

# Export / Import Settings: what goes in the file and how it merges.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "tmpdir"
require "tn3270"
require "tn3270/gui/settings_transfer"

class SettingsTransferTest < Minitest::Test
  ST = Tn3270::Gui::SettingsTransfer
  Snip = Struct.new(:name, :text)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.remove_entry(@dir)

  def config(name, values = {})
    c = Tn3270::Gui::Config.load(File.join(@dir, name))
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
    mine = config("b.yml", "spell_ignore" => ["JCL"], "keys" => { "F13" => "pf13" },
                           "connections" => [{ "name" => "PROD", "host" => "old", "port" => 23 },
                                             { "name" => "Mine", "host" => "m", "port" => 23 }])
    bundle = { "options" => { "caps" => true, "spell_ignore" => ["TSO"], "keys" => { "F14" => "pf14" },
                              "recent" => ["X"] },
               "connections" => [{ "name" => "prod", "host" => "new", "port" => 992, "tls" => true }],
               "snippets" => [{ "name" => "Logon", "text" => "x" }] }
    path = File.join(@dir, "in.yml")
    File.write(path, bundle.merge(ST::MARK => 1).to_yaml)
    snippets = ST.apply(ST.read(path), mine)
    assert mine["caps"]
    assert_equal %w[JCL TSO], mine["spell_ignore"]
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
