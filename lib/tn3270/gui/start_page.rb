# frozen_string_literal: true

require_relative "theme"

module Tn3270
  module Gui
    # The new tab page: a tab that hasn't connected yet lists the saved
    # sessions to open, most recently used first. Included into TerminalWindow.
    module StartPage
      include Theme

      START_W = 460
      START_ROW_H = 44

      # (The engine reports a blank screen even before connecting, so "new"
      # means the tab has never been asked to connect anywhere.)
      def start_page? = @controller.last_target.nil? && !@controller.connecting?

      def draw_start_page(w)
        pt = @painter
        @start_hits = HitMap.new
        sessions = recent_connections.first(9)
        x = [((w - panel_w - START_W) / 2.0), 16].max
        y = header_h + 48
        pt.text(x, y, START_W, "Open a session", WHITE, UI_FONT, UI_SIZE * 1.5, bold: true)
        y += 40
        if (src = duplicate_source)
          hover = @start_hover == [:duplicate]
          pt.fill_rect(x, y, START_W, START_ROW_H - 4, SELECTION, hover ? 0.30 : 0.18)
          ui_text(x + 12, y + 12, "D", TITLE_MUTED)
          ui_text(x + 36, y + 4, fit_text("Duplicate \"#{src.title}\"", START_W - 48), WHITE)
          ui_text(x + 36, y + 4 + ui_line_h, "Another connection to the session in the tab you came from", TITLE_MUTED)
          @start_hits.add(x, y, START_W, START_ROW_H - 4, [:duplicate])
          y += START_ROW_H + 12
        end
        if sessions.empty?
          ui_text(x, y, "No saved sessions yet.", TITLE_MUTED)
          y += 30
        end
        sessions.each_with_index do |conn, i|
          hover = @start_hover == [:session, i]
          pt.fill_rect(x, y, START_W, START_ROW_H - 4, TAB_HOVER, hover ? 0.10 : 0.04)
          ui_text(x + 12, y + 12, (i + 1).to_s, TITLE_MUTED)
          ui_text(x + 36, y + 4, fit_text(conn["name"].to_s, START_W - 48), WHITE)
          ui_text(x + 36, y + 4 + ui_line_h, fit_text(Config.display_string(conn), START_W - 48), TITLE_MUTED)
          @start_hits.add(x, y, START_W, START_ROW_H - 4, [:session, i])
          y += START_ROW_H
        end
        label = "Connections..."
        bw = FontMetrics.text_width(UI_FONT, UI_SIZE, label) + 24
        hover = @start_hover == [:connections]
        pt.fill_rect(x, y + 8, bw, 28, TAB_HOVER, hover ? 0.16 : 0.08)
        ui_text(x + 12, y + 14, label, TITLE_FG)
        @start_hits.add(x, y + 8, bw, 28, [:connections])
        hint = "Press 1-#{[sessions.size, 1].max} to open, or #{keys_label('new_tab')} for another tab"
        ui_text(x + bw + 16, y + 14, hint, TITLE_MUTED) unless sessions.empty?
      end

      def start_page_click(hit)
        case hit[0]
        when :session then (conn = recent_connections[hit[1]]) && connect_to(conn)
        when :connections then UI.queue_main { connections_dialog }
        when :duplicate then (src = duplicate_source) && duplicate_session(src)
        end
      end

      # 1-9 on the new tab page opens that session, D duplicates. True if it did.
      def start_page_number(char)
        if char.casecmp?("d") && (src = duplicate_source)
          duplicate_session(src)
          return true
        end
        return false unless char.match?(/\A[1-9]\z/)

        conn = recent_connections.first(9)[char.to_i - 1]
        conn && connect_to(conn)
        !conn.nil?
      end

      def start_hover_at(event)
        hit = start_page? ? @start_hits.at(event) : nil
        return if hit == @start_hover

        @start_hover = hit
        redraw
      end

      # Saved connections, most recently used first.
      def recent_connections
        order = Array(@config["recent"])
        @config.connections.each_with_index
               .sort_by { |c, i| [order.index(c["name"]) || order.size, i] }
               .map(&:first)
      end
    end
  end
end
