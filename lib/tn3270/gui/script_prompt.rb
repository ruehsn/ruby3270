# frozen_string_literal: true

require_relative "ui"
require_relative "dialogs"
require_relative "clipboard"
require_relative "win32"

module Tn3270
  module Gui
    # What a script asks of the person at the window (Session#ask, #choose)
    # or shows them (Session#show), each in a small window of its own. The
    # 3270 screen never gets the typing, and the terminal's keyboard is left
    # alone. Windows sit over the tab's window (Windows: owned by it, so they
    # stay in front of it but don't block it).
    #
    # A request comes from Instance as {"ui" => {...}, "id", "reply" => Queue}.
    # Every request is answered exactly once: {"value" => ...}, {"cancel" =>
    # true}, {"stop" => true} (Stop Script) or {"ok" => true}.
    class ScriptPrompt
      include DialogSupport

      attr_reader :id, :tab

      # owner: the libui window it belongs over; on_done: called once it's
      # closed and answered.
      def initialize(request, tab:, owner:, on_done:)
        @ui = request["ui"]
        @id = request["id"]
        @reply = request["reply"]
        @tab = tab
        @owner = owner
        @on_done = on_done
        @done = false
      end

      def show
        @win = Ui.window("Script: #{title}", 480, 150 + (prompt_lines * 18))
        UI.window_on_closing(@win) do
          finish({ "cancel" => true }, false)
          1
        end
        box = Ui.vbox
        Ui.add(box, Ui.label(@ui["prompt"].to_s))
        @ui["kind"] == "choose" ? add_choices(box) : add_entry(box)
        @note = Ui.add(box, Ui.label(""))
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.button("Stop Script") { finish("stop" => true) })
        Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("OK") { ok })
        Ui.add(row, Ui.button("Cancel") { finish("cancel" => true) })
        UI.window_set_child(@win, box)
        ScriptPrompt.place_over(@win, @owner)
        show_window(@win)
        Win32.focus_control(@entry) if @entry
      end

      # Stop Script (status bar, menu) while this is open.
      def stop = finish("stop" => true)

      # The script went away (stopped, ended, its tab closed): close without
      # an answer.
      def gone
        @done = true
        close_window(@win) if @win
        @on_done.call(self)
      end

      # Puts `win` over the middle of `owner`, and (Windows) makes `owner` own
      # it, so it stays in front of the terminal window.
      def self.place_over(win, owner)
        return unless owner && Win32.available?

        Win32.set_owner(win, owner)
        l, t, r, b = Win32.window_rect(owner)
        w, h = Win32.window_size(win)
        Win32.move(win, l + ((r - l - w) / 2), t + ((b - t - h) / 3))
      rescue StandardError
        nil
      end

      private

      def title = (@ui["title"].to_s.strip.empty? ? "Question" : @ui["title"])
      def prompt_lines = [@ui["prompt"].to_s.lines.size, 1].max

      def add_entry(box)
        @entry = @ui["secret"] ? UI.new_password_entry : UI.new_entry
        UI.entry_set_text(@entry, @ui["default"].to_s)
        Ui.add(box, @entry)
      end

      # A drop-down list for a short list; a list to scroll (double-click
      # picks) for a long one.
      def add_choices(box)
        options = @ui["options"]
        start = options.index(@ui["default"]) || 0
        if options.size <= 15
          @combo = Ui.add(box, Ui.combobox(options, selected: start))
        else
          @table = Ui::Table.new(["Choice"], options.map { |o| [o] }) { |row| pick(row) }
          Ui.add(box, @table.control, stretchy: true)
          UI.window_set_content_size(@win, 480, 380)
        end
      end

      def ok
        return finish("value" => Ui.entry_text(@entry)) if @entry
        return pick(UI.combobox_selected(@combo)) if @combo

        row = @table.selected
        row ||= @ui["options"].index(@ui["default"])
        row ? pick(row) : UI.label_set_text(@note, "Pick one first (or double-click it).")
      end

      def pick(row)
        choice = row && row >= 0 ? @ui["options"][row] : nil
        finish(choice ? { "value" => choice } : { "cancel" => true })
      end

      def finish(answer, close = true)
        return if @done

        @done = true
        @reply << answer
        close_window(@win) if close
        @on_done.call(self)
      end
    end

    # Text a script shows (Session#show): read-only, can be copied. Showing
    # again with the same title on the same tab replaces the text, so a
    # script can keep one window up to date. Requests with wait: true are
    # answered when it closes.
    class ScriptTextWindow
      include DialogSupport

      attr_reader :tab, :title

      def initialize(tab:, title:, owner:, on_done:)
        @tab = tab
        @title = title
        @owner = owner
        @on_done = on_done
        @waiting = []
        @open = false
      end

      def open? = @open

      # Shows the request's text (opening the window the first time). The
      # terminal window keeps the keyboard.
      def update(request)
        ui = request["ui"]
        open_window unless @open
        UI.multiline_entry_set_text(@body, ui["text"].to_s.delete("\r")) # libui makes the line ends Windows ones
        ui["wait"] ? @waiting << request["reply"] : request["reply"] << { "ok" => true }
      end

      # Stop Script: the waiting script gets stopped; the text stays up.
      def stop
        @waiting.each { |r| r << { "stop" => true } }
        @waiting.clear
      end

      def close
        close_window(@win) if @open
        closed
      end

      private

      def open_window
        @win = Ui.window(@title, 640, 420)
        UI.window_on_closing(@win) do
          closed
          1
        end
        box = Ui.vbox
        @body = Ui.keep(UI.new_non_wrapping_multiline_entry)
        UI.multiline_entry_set_read_only(@body, 1)
        Win32.monospace(@body) # screen text keeps its columns
        Ui.add(box, @body, stretchy: true)
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.button("Copy All") { Clipboard.copy(Ui.take_text(UI.multiline_entry_text(@body)).delete("\r")) })
        Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("Close") { close })
        UI.window_set_child(@win, box)
        ScriptPrompt.place_over(@win, @owner)
        show_window(@win)
        Win32.focus(@owner) if @owner # keep typing going to the terminal
        @open = true
      end

      def closed
        return unless @open

        @open = false
        @waiting.each { |r| r << { "ok" => true } }
        @waiting.clear
        @on_done.call(self)
      end
    end

    # Program's side of script prompts: routes each request to its tab's
    # window and keeps track of what's open, for Stop Script.
    module ScriptPrompts
      # A request from Instance: {"ui", "id", "reply"}.
      def script_request(request)
        ui = request["ui"]
        tab, window = tab_with_port(ui["port"])
        window ||= active_window
        tab ||= window&.current_tab
        return request["reply"] << { "cancel" => true } unless window && tab

        case ui["kind"]
        when "notify"
          tab.controller.flash(ui["text"].to_s)
          request["reply"] << { "ok" => true }
        when "show" then script_show(request, tab, window)
        else
          prompt = ScriptPrompt.new(request, tab: tab, owner: window.ui_window, on_done: ->(p) { prompt_done(p) })
          open_prompts << prompt
          prompt.show
        end
        window.command(:redraw)
      end

      # The script that asked went away before an answer.
      def script_request_gone(id)
        open_prompts.find { |p| p.id == id }&.gone
      end

      # Whether a script on this tab is waiting for the person.
      def prompt_open?(tab) = open_prompts.any? { |p| p.tab.equal?(tab) }

      # Stop Script: questions from scripts on this tab are answered "stop".
      def stop_prompts(tab)
        open_prompts.select { |p| p.tab.equal?(tab) }.each(&:stop)
        text_windows.select { |t| t.tab.equal?(tab) }.each(&:stop)
      end

      private

      def open_prompts = (@open_prompts ||= [])
      def text_windows = (@text_windows ||= [])

      def prompt_done(prompt)
        open_prompts.delete(prompt)
        @windows.each { |w| w.command(:redraw) }
      end

      def script_show(request, tab, window)
        title = request["ui"]["title"].to_s
        view = text_windows.find { |t| t.tab.equal?(tab) && t.title == title && t.open? }
        unless view
          view = ScriptTextWindow.new(tab: tab, title: title, owner: window.ui_window,
                                      on_done: ->(t) { text_windows.delete(t) })
          text_windows << view
        end
        view.update(request)
      end

      # [tab, window] for the tab whose script port is `port`.
      def tab_with_port(port)
        return [nil, nil] unless port

        @windows.each do |w|
          tab = w.tabs.find { |t| t.controller.attach_port == port }
          return [tab, w] if tab
        end
        [nil, nil]
      end
    end
  end
end
