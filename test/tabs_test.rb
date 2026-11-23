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
require "tn3270/gui/hit_map"
require "tn3270/gui/theme"

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

  # A script asks for a tab and is told its script port.
  def test_open_tab_returns_the_new_tabs_port
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      app = Thread.new do
        got = nil
        50.times do
          got = running.requests.first
          break if got

          sleep 0.05
        end
        got["reply"] << 3275
        got
      end
      assert_equal 3275, I.open_tab({ "host" => "x:23" }, path: path, timeout: 5)
      request = app.value
      assert_equal "x:23", request["host"]
      refute request.key?("want")
      running.close
      assert_nil I.open_tab({ "host" => "x:23" }, path: path) # nothing running
    end
  end

  # Session.attach(tab: "name") asks the app for that tab's port.
  def test_find_tab_asks_for_a_tab_by_name
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      Thread.new do
        sleep 0.05 until (r = running.requests.first)
        r["reply"] << (r["tab"] == "Payroll" ? 3281 : nil)
      end
      assert_equal 3281, I.find_tab("Payroll", path: path)
      Thread.new do
        sleep 0.05 until (r = running.requests.first)
        r["reply"] << nil
      end
      e = assert_raises(Tn3270::Error) { I.find_tab("Nope", path: path) }
      assert_match(/No tab named "Nope"/, e.message)
      running.close
    end
  end

  def test_open_tab_says_when_the_tab_has_no_port
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      Thread.new do
        sleep 0.1 until (r = running.requests.first)
        r["reply"] << nil
      end
      assert_raises(Tn3270::Error) { I.open_tab({ "host" => "x:23" }, path: path, timeout: 5) }
      running.close
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

  # A script asks the person something (Session#ask) and waits for the answer.
  def test_a_scripts_question_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      app = Thread.new do
        sleep 0.05 until (r = running.requests.first)
        r["reply"] << { "value" => "USER01A" }
        r
      end
      reply = I.user_request({ "kind" => "ask", "prompt" => "Job name?", "port" => 3271 }, path: path)
      assert_equal({ "value" => "USER01A" }, reply)
      request = app.value
      assert_equal "ask", request["ui"]["kind"]
      assert_equal 3271, request["ui"]["port"]
      assert request["id"]
      running.close
      assert_raises(Tn3270::Error) { I.user_request({ "kind" => "ask" }, path: path) } # nothing running
    end
  end

  # The script is stopped (killed) while its question is open: the app hears so.
  def test_a_script_that_goes_away_is_reported
    Dir.mktmpdir do |dir|
      path = File.join(dir, "instance")
      running = I.new(path: path)
      info = JSON.parse(File.read(path))
      sock = Socket.tcp("127.0.0.1", info["port"])
      sock.write("#{JSON.generate('token' => info['token'], 'ui' => { 'kind' => 'ask' })}\n")
      sleep 0.05 until (asked = running.requests.first)
      sock.close
      gone = nil
      60.times do
        gone = running.requests.find { |r| r.key?("ui_gone") }
        break if gone

        sleep 0.05
      end
      assert_equal asked["id"], gone["ui_gone"]
      running.close
    end
  end

  def test_ui_requests_keep_only_known_fields
    line = JSON.generate("token" => "t", "ui" => { "kind" => "choose", "prompt" => "Which?", "options" => ["A", 2, "B"],
                                                   "port" => "3271", "evil" => "x", "title" => "T" * 300 })
    ui = I.parse_ui(line, "t")
    assert_equal %w[A B], ui["options"]
    assert_equal 200, ui["title"].size
    refute ui.key?("port") # not a number
    refute ui.key?("evil")
    assert_nil I.parse_ui(line, "wrong")
    assert_nil I.parse_ui(JSON.generate("token" => "t", "ui" => { "kind" => "format_disk" }), "t")
    assert_nil I.parse(line, "t") # not an open request
  end

  def test_session_asks_through_the_window_and_can_be_stopped
    s = Tn3270::Session.new(engine: Object.new)
    s.window_port = 3272
    sent = nil
    answer = { "value" => "TEST" }
    fake = lambda do |ui|
      sent = ui
      answer
    end
    original = I.method(:user_request)
    I.define_singleton_method(:user_request) { |ui, **| fake.call(ui) }
    begin
      assert_equal "TEST", s.choose("Which system?", %w[PROD TEST])
      assert_equal 3272, sent["port"]
      answer = { "value" => "OTHER" }
      assert_nil s.choose("Which system?", %w[PROD TEST]) # only a listed option comes back
      answer = { "cancel" => true }
      assert_nil s.ask("Job name?")
      answer = { "stop" => true }
      assert_raises(Tn3270::ScriptStopped) { s.ask("Job name?") }
    ensure
      I.define_singleton_method(:user_request, original)
    end
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

class TabColorTest < Minitest::Test
  FakeController = Struct.new(:last_target)

  def tab(config, target) = Tn3270::Gui::Tab.new(config, controller: FakeController.new(target))

  def test_a_saved_session_gives_its_tabs_its_color
    prod = { "name" => "PROD", "host" => "prod.example", "port" => 992, "color" => "red" }
    config = { "connections" => [prod, { "name" => "TEST", "host" => "test.example", "port" => 23 }] }
    assert_equal "red", tab(config, prod.dup).color
    assert_nil tab(config, config["connections"][1]).color
    # typed as host:port, it is still that session
    assert_equal "red", tab(config, { "name" => "", "host" => "PROD.example", "port" => 992 }).color
    # the color follows the saved session when it is edited later
    t = tab(config, prod.merge("color" => ""))
    prod["color"] = "blue"
    assert_equal "blue", t.color
    assert Tn3270::Gui::Theme::TAB_COLORS.key?(t.color)
  end

  def test_a_session_that_is_not_saved_keeps_a_color_of_its_own
    t = tab({ "connections" => [] }, { "name" => "10.0.0.9:23", "host" => "10.0.0.9", "port" => 23 })
    assert_nil t.color
    assert_nil t.saved_connection
    t.color = "green"
    assert_equal "green", t.color
    t.color = nil
    assert_nil t.color
    assert_nil tab({}, nil).color # a new tab
  end
end

class HitMapTest < Minitest::Test
  def test_the_first_thing_added_at_a_point_wins
    map = Tn3270::Gui::HitMap.new
    assert_nil map.at(x: 5, y: 5)
    map.add(90, 0, 10, 10, [:tab_close, 0]).add(0, 0, 100, 10, [:tab, 0]).add(100, 0, 20, 10, :new_tab)
    assert_equal [:tab_close, 0], map.at(x: 95, y: 5) # the close button is on the tab
    assert_equal [:tab, 0], map.at(x: 50, y: 5)
    assert_equal :new_tab, map.at(x: 110, y: 10)
    assert_nil map.at(x: 50, y: 11)
    assert_equal [0, 0, 100, 10], map.rect([:tab, 0])
    assert_nil map.rect(:missing)
  end
end

require "tn3270/gui/dialogs"

# Save never makes a desktop shortcut; one that exists follows a rename and
# goes with a delete.
class ShortcutFollowTest < Minitest::Test
  D = Tn3270::Gui::ConnectionsDialog
  S = Tn3270::Gui::Shortcut

  def with_fake_shortcuts(existing)
    log = []
    saved = %i[remove create path_for].to_h { |m| [m, S.method(m)] }
    S.define_singleton_method(:path_for) { |c| "#{c['name']}.lnk" }
    S.define_singleton_method(:remove) { |c| existing.include?(c["name"]) && (log << [:remove, c["name"]]) }
    S.define_singleton_method(:create) { |c| log << [:create, c["name"]] }
    yield log
  ensure
    saved.each { |m, fn| S.define_singleton_method(m, fn) }
  end

  def test_a_renamed_session_keeps_its_shortcut_and_a_deleted_one_loses_it
    before = [{ "name" => "PROD" }, { "name" => "TEST" }, { "name" => "DEV" }]
    dialog = D.allocate
    dialog.instance_variable_set(:@list, [{ "name" => "PROD-1" }, { "name" => "DEV" }])
    dialog.instance_variable_set(:@renamed, { "PROD" => "PROD-1" })
    with_fake_shortcuts(%w[PROD TEST]) do |log|
      dialog.send(:update_shortcuts, before)
      assert_equal [[:remove, "PROD"], [:create, "PROD-1"], [:remove, "TEST"]], log
    end
  end
end
