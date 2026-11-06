# frozen_string_literal: true

# Snippet parsing, and snippets typed into the built-in FakeHost:
#   ruby -Ilib test/snippet_test.rb
require "minitest/autorun"
require "tn3270"
require "tn3270/fake_host"

class SnippetParseTest < Minitest::Test
  S = Tn3270::Snippet

  def test_text_and_keys
    assert_equal [[:text, "=3.4"], [:key, :enter]], S.parse("=3.4{Enter}")
    assert_equal [[:key, :pf8], [:key, :pa2], [:key, :erase_eof]], S.parse("{pf8}{PA2}{EraseEOF}")
  end

  def test_new_lines_move_to_the_next_field_unless_a_key_already_did
    assert_equal [[:text, "a"], [:key, :newline], [:text, "b"]], S.parse("a\nb")
    assert_equal [[:text, "a"], [:key, :enter], [:text, "b"]], S.parse("a{Enter}\nb")
    assert_equal [[:text, "a"]], S.parse("a\n") # a trailing newline means nothing
  end

  def test_wait_ask_and_variables
    steps = S.parse("{wait:READY}{ask:Job name}{date:%y}")
    assert_equal [[:wait, "READY"], [:ask, "Job name"], [:var, "date", "%y"]], steps
    assert_equal ["Job name", "Class"], S.prompts("{ask:Job name} {ask:Class} {ask:Job name}")
  end

  def test_braces_and_unknown_tokens
    assert_equal [[:text, "{"], [:text, "x}"]], S.parse("{{x}")
    assert_equal ["{Bogus}"], S.unknown_tokens("a{Bogus}{Enter}")
    assert_equal [[:text, "a"], [:text, "{Bogus}", "{Bogus}"]], S.parse("a{Bogus}")
  end

  def test_expand_answers_and_variables
    steps = S.expand(S.parse("{ask:Name}/{user}/{clipboard}"), { "Name" => "JOB1" }, { user: "ME", clipboard: "one\ntwo" })
    texts = steps.map { |k, v| k == :text ? v : "<#{v}>" }.join
    assert_equal "JOB1/ME/one<newline>two", texts
    assert_match(/\A\d{4}-\d\d-\d\d\z/, S.expand(S.parse("{date}"), {}, {}).first[1])
  end
end

class SnippetRunTest < Minitest::Test
  def setup
    @host = Tn3270::FakeHost.new(port: 0, log: nil).start
    @s = Tn3270::Session.open("127.0.0.1:#{@host.port}", rows: 24, cols: 80, timeout: 5)
    @s.wait_for_text("USER ID")
  end

  def teardown
    @s&.close
    @host&.stop
  end

  def test_a_snippet_signs_on_and_drives_menus
    # USER ID, next field (password), Enter, wait for the menu, option 1, Enter.
    @s.type_snippet("user01\nsecret{Enter}{wait:MAIN MENU}1{Enter}{wait:KEY TESTER}{PF15}")
    assert @s.on_screen?(/Last AID received:\s+PF15/)
    assert @s.on_screen?("KEY TESTER")
  end

  def test_answers_fill_ask_placeholders
    @s.type_snippet("{ask:Who}{Enter}{wait:MAIN MENU}", answers: { "Who" => "asked" })
    assert @s.on_screen?("Signed on as ASKED")
  end
end

require "tmpdir"
require "tn3270/gui/config"
require "tn3270/gui/snippet_library"

class SnippetLibraryTest < Minitest::Test
  L = Tn3270::Gui::SnippetLibrary

  def setup
    @dir = Dir.mktmpdir
    @mine = File.join(@dir, "mine.yml")
    @team = File.join(@dir, "team")
    Dir.mkdir(@team)
    File.write(File.join(@team, "a.yml"), [{ "name" => "Data set list", "text" => "=3.4{Enter}" }].to_yaml)
    File.write(File.join(@team, "b.yml"), [{ "name" => "SDSF", "text" => "=S.ST{Enter}" }].to_yaml)
    @config = Tn3270::Gui::Config.load(File.join(@dir, "cfg.yml"))
    @config["personal_snippets"] = @mine
    @config["snippet_files"] = [@team]
    @lib = L.new(@config)
    @lib.reload_if_changed
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_reads_a_shared_folder_and_saves_new_ones_to_my_file
    assert_equal ["Data set list", "SDSF"], @lib.items.map(&:name)
    @lib.save(nil, "Sign on", "user01{Enter}", @lib.personal_file)
    assert_equal [{ "name" => "Sign on", "text" => "user01{Enter}" }], YAML.safe_load_file(@mine)
    assert_equal 3, @lib.items.size
  end

  def test_search_puts_name_matches_first
    @lib.save(nil, "Status", "=S.ST{Enter}", @lib.personal_file)
    assert_equal ["SDSF", "Status"], @lib.search("s.st").map(&:name)
    assert_equal ["Status"], @lib.search("stat").map(&:name)
    assert_equal ["SDSF"], @lib.search("sdsf enter").map(&:name) # every word must match
  end

  def test_moving_a_snippet_to_another_file
    item = @lib.items.find { |i| i.name == "SDSF" }
    @lib.save(item, "SDSF", item.text, @lib.personal_file)
    assert_equal [], YAML.safe_load_file(File.join(@team, "b.yml"))
    assert_equal ["SDSF"], YAML.safe_load_file(@mine).map { |e| e["name"] }
  end

  def test_a_broken_file_is_reported_not_fatal
    File.write(File.join(@team, "c.yml"), "name: [oops")
    @lib.reload_if_changed
    assert_equal 2, @lib.items.size
    assert_match(/c\.yml/, @lib.errors.first)
  end

  def test_shared_entries_are_added_and_removed
    other = File.join(@dir, "other.yml")
    L.create_file(other)
    @lib.add_shared(other)
    assert_includes @lib.files, other
    @lib.remove_shared(other)
    refute_includes @lib.files, other
  end
end
