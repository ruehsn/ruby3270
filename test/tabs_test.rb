# frozen_string_literal: true

# Session tabs without a window: strip layout and reordering, tab titles,
# the one-running-copy handoff, and the tab keys.
#   ruby -Ilib test/tabs_test.rb
require "minitest/autorun"
require "tmpdir"
require "tn3270"
require "tn3270/gui/tab"
require "tn3270/gui/instance"
require "tn3270/gui/keymap"

class TabStripTest < Minitest::Test
  S = Tn3270::Gui::TabStrip

  def test_tabs_share_the_strip_up_to_a_maximum_width
    width, lefts = S.layout(3, 100, 1000)
    assert_equal S::MAX_W, width # plenty of room: full width
    assert_equal [100, 320, 540], lefts

    width, lefts = S.layout(10, 0, 530)
    assert_in_delta 50.0, width # (530 - the + button) / 10
    assert_in_delta 450.0, lefts.last
  end

  def test_tabs_stop_shrinking_at_the_minimum
    width, = S.layout(50, 0, 300)
    assert_equal S::MIN_W, width
  end

  def test_no_tabs
    assert_equal [], S.layout(0, 0, 500)[1]
  end

  def test_dragging_a_tab_right_past_the_next_ones_middle
    _, lefts = S.layout(3, 0, 1000) # 0, 220, 440
    assert_equal 0, S.drop_index(lefts, 220, 0, 100)  # not past tab 1's middle yet
    assert_equal 1, S.drop_index(lefts, 220, 0, 230)  # dragged middle 340 is past tab 1's (330)
    assert_equal 2, S.drop_index(lefts, 220, 0, 500)
  end

  def test_dragging_a_tab_left
    _, lefts = S.layout(3, 0, 1000)
    assert_equal 2, S.drop_index(lefts, 220, 2, 440)
    assert_equal 1, S.drop_index(lefts, 220, 2, 200)
    assert_equal 0, S.drop_index(lefts, 220, 2, -50)
  end

  def test_where_a_tab_from_another_window_goes
    _, lefts = S.layout(2, 0, 1000) # middles at 110 and 330
    assert_equal 0, S.insert_index(lefts, 220, 50)
    assert_equal 1, S.insert_index(lefts, 220, 200)
    assert_equal 2, S.insert_index(lefts, 220, 900)
  end

  def test_move
    assert_equal %w[b a c], S.move(%w[a b c], 0, 1)
    assert_equal %w[c a b], S.move(%w[a b c], 2, 0)
    assert_equal %w[b c a], S.move(%w[a b c], 0, 9)
  end
end

class TabTitleTest < Minitest::Test
  FakeController = Struct.new(:last_target, :up, :trying) do
    def connected? = up
    def connecting? = trying
  end

  def tab(target, up: false, trying: false)
    Tn3270::Gui::Tab.new({}, controller: FakeController.new(target, up, trying))
  end

  def test_titles
    assert_equal "New Tab", tab(nil).title
    assert_equal "Prod LPAR", tab({ "name" => "Prod LPAR", "host" => "10.1.1.1", "port" => 23 }).title
    assert_nil tab({ "name" => "  ", "host" => "h", "port" => 23 }).name
  end

  def test_a_plain_address_takes_its_saved_sessions_name
    config = { "connections" => [{ "name" => "Local fake host", "host" => "127.0.0.1", "port" => 3270 }] }
    t = Tn3270::Gui::Tab.new(config, controller: FakeController.new({ "host" => "127.0.0.1", "port" => 3270 }))
    assert_equal "Local fake host", t.title
    other = Tn3270::Gui::Tab.new(config, controller: FakeController.new({ "host" => "10.0.0.9", "port" => 23 }))
    assert_equal "10.0.0.9:23", other.title # not saved: nothing else to call it
  end

  def test_a_renamed_tab_shows_its_name_and_frees_its_number
    prod = { "name" => "PROD", "host" => "h", "port" => 23 }
    a, b = tab(prod), tab(prod)
    Tn3270::Gui::Tab.number_all([a, b])
    b.custom_title = "  Batch jobs "
    c = tab(prod)
    Tn3270::Gui::Tab.number_all([a, b, c])
    assert_equal ["PROD", "Batch jobs", "PROD (2)"], [a, b, c].map(&:title)
    b.custom_title = "" # back to the session's name
    Tn3270::Gui::Tab.number_all([a, b, c])
    assert_equal "PROD (3)", b.title
  end

  def test_tabs_on_the_same_session_are_numbered
    prod = { "name" => "PROD", "host" => "h", "port" => 23 }
    a, b, c, other = tab(prod), tab(prod), tab(prod), tab({ "name" => "TEST", "host" => "t", "port" => 23 })
    Tn3270::Gui::Tab.number_all([a, b, c, other])
    assert_equal ["PROD", "PROD (2)", "PROD (3)", "TEST"], [a, b, c, other].map(&:title)

    # Closing (2) leaves (3) alone; the next one takes the free number.
    d = tab(prod)
    Tn3270::Gui::Tab.number_all([a, c, other, d])
    assert_equal ["PROD", "PROD (3)", "TEST", "PROD (2)"], [a, c, other, d].map(&:title)

    # A tab that moves to another session takes that session's next number.
    a.controller.last_target = { "name" => "TEST", "host" => "t", "port" => 23 }
    Tn3270::Gui::Tab.number_all([a, c, other, d])
    assert_equal "TEST (2)", a.title
  end

  def test_state
    assert_equal :offline, tab(nil).state
    assert tab(nil).idle?
    assert_equal :connecting, tab(nil, trying: true).state
    assert_equal :connected, tab(nil, up: true).state
    refute tab(nil, up: true).idle?
  end
end

class InstanceTest < Minitest::Test
  I = Tn3270::Gui::Instance

  def test_hands_a_session_to_the_running_copy
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      assert running.listening?
      assert I.forward({ "session" => "Prod LPAR" }, path: path)
      assert I.forward({}, path: path)
      got = []
      20.times do
        got.concat(running.requests)
        break if got.size == 2

        sleep 0.05
      end
      assert_equal [{ "session" => "Prod LPAR" }, {}], got
      running.close
      refute File.exist?(path)
      refute I.forward({ "session" => "x" }, path: path) # nothing running
    end
  end

  def test_needs_the_token
    assert_nil I.parse('{"token":"wrong","open":{}}', "right")
    assert_nil I.parse("not json", "right")
    assert_equal({}, I.parse('{"token":"right","open":{}}', "right"))
  end

  def test_keeps_only_known_short_fields
    line = JSON.generate("token" => "t", "open" => { "session" => "A", "host" => "x" * 300, "evil" => "1" })
    assert_equal({ "session" => "A" }, I.parse(line, "t"))
  end

  def test_a_stale_file_is_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close # nobody listening there any more
      File.write(path, JSON.generate("port" => port, "token" => "abc"))
      refute I.forward({}, path: path, timeout: 0.5)
    end
  end
end

class TabKeysTest < Minitest::Test
  K = Tn3270::Gui::Keymap

  def ev(**h) = { up: false, modifiers: [] }.merge(h)

  def test_tab_keys
    assert_equal [:new_tab], K.translate(ev(key: "t", modifiers: [:control]))
    assert_equal [:close_tab], K.translate(ev(key: "w", modifiers: [:control]))
    assert_equal [:new_window], K.translate(ev(key: "n", modifiers: [:control]))
    assert_equal [:next_tab], K.translate(ev(key: "\t", key_value: 9, modifiers: [:control]))
    assert_equal [:prev_tab], K.translate(ev(key: "\t", key_value: 9, modifiers: %i[control shift]))
  end
end

require "tn3270/gui/program"

class PickerSettingsTest < Minitest::Test
  T = Tn3270::Gui::Program::Toggle
  LIST = [T.new(:caps, "Caps Lock (this app only)", "uppercase capitals", false),
          T.new("Underline Input Fields", "Underline Input Fields", "fields", true),
          T.new(:auto_enter, "Auto Enter (press Enter every 2s, to watch a job)", "refresh repeat", false)].freeze

  def match(q) = Tn3270::Gui::Program.match_toggles(LIST, q).map(&:name)

  def test_every_word_must_match_label_or_extra_words
    assert_equal [:caps], match("caps")
    assert_equal [:caps], match("UPPER")
    assert_equal ["Underline Input Fields"], match("under fields")
    assert_equal [:auto_enter], match("auto enter")
    assert_equal [], match("caps fields")
  end

  def test_an_empty_query_shows_no_settings
    assert_equal [], match("")
    assert_equal [], match("   ")
  end
end

# Session > Edit Session opens the connections dialog on the tab's session.
class EditSessionTest < Minitest::Test
  def dialog(select)
    require "tn3270/gui/dialogs"
    config = Tn3270::Gui::Config.new(Tn3270::Gui::Config::DEFAULTS.merge(
                                       "connections" => [{ "name" => "Dev", "host" => "dev", "port" => 23 },
                                                         { "name" => "Prod", "host" => "prod", "port" => 992 }]
                                     ), File::NULL)
    Tn3270::Gui::ConnectionsDialog.new(config, on_connect: ->(_) {}, select: select)
  end

  def test_opens_on_the_saved_connection
    assert_equal "Prod", dialog({ "name" => "Prod", "host" => "prod", "port" => 992 }).current["name"]
    assert_equal "Dev", dialog({ "name" => "dev:23", "host" => "dev", "port" => 23 }).current["name"] # same host
  end

  def test_a_typed_connection_is_added_for_saving
    d = dialog(Tn3270::Gui::Config.connection_from_string("other:3270"))
    assert_equal "other:3270", d.current["name"]
    assert_equal "other", d.current["host"]
  end
end

class DuplicateConnectionNameTest < Minitest::Test
  def copy(n, taken) = (require "tn3270/gui/dialogs"; Tn3270::Gui::ConnectionsDialog.copy_name(n, taken))

  def test_next_free_number
    assert_equal "Prod (2)", copy("Prod", ["Prod"])
    assert_equal "Prod (3)", copy("Prod", ["Prod", "Prod (2)"])
    assert_equal "Prod (3)", copy("Prod (2)", ["Prod", "Prod (2)"]) # a copy of a copy
  end
end
