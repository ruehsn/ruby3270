# frozen_string_literal: true

module Tn3270
  module Gui
    # Ctrl+Z for a Controller: takes back the last paste, snippet, spelling
    # fix or run of typing, until the host sends a new screen (Enter, PF...
    # clear the list). Everything here except `undo` and `can_undo?` runs on
    # the controller's worker thread.
    module ControllerUndo
      # What Ctrl+Z puts back: the input fields' text (or, on an unformatted
      # screen, each row) and the cursor, from before a paste or some typing.
      UndoPoint = Struct.new(:fields, :rows, :cursor, :records, :what)
      UNDO_LIMIT = 20

      def undo
        enqueue(input: true) do
          undo_now
          notify
        end
      end

      def can_undo? = @undo.any?

      private

      # Saves what the screen's input looks like now, so Ctrl+Z can put it
      # back. Returns the screen it read.
      def undo_point(what)
        @typing = false
        screen = @session.screen
        fields = screen.input_fields.map { |f| [f.row, f.col, f.length, f.value.to_s] } unless screen.fields.empty?
        rows = (0...screen.rows).map { |r| screen.row_text(r) } if screen.fields.empty?
        point = UndoPoint.new(fields, rows, [screen.cursor_row, screen.cursor_col], records_received, what)
        @undo = (@undo + [point]).last(UNDO_LIMIT)
        screen
      end

      # Typed characters and editing keys up to the next other action form
      # one undo step.
      def typing
        undo_point("typing") unless @typing
        @typing = true
        yield
      end

      def forget_undo
        @undo = []
        @typing = false
      end

      def undo_now
        @typing = false
        point = @undo.pop
        return @message = "Nothing to undo" unless point
        if point.records != records_received
          forget_undo
          return @message = "Can't undo: the host has changed the screen since"
        end

        screen = @session.screen
        return unless (restored = point.fields ? restore_fields(point, screen) : restore_rows(point, screen))

        @session.move_to(*point.cursor)
        @message = restored.zero? ? "Undid #{point.what} (nothing had changed)" : "Undid #{point.what}"
      end

      # Puts back each input field whose text differs; returns how many.
      def restore_fields(point, screen)
        now = screen.input_fields.to_h { |f| [[f.row, f.col, f.length], f.value.to_s] }
        unless point.fields.all? { |r, c, len, _| now.key?([r, c, len]) }
          forget_undo
          @message = "Can't undo: the screen's fields have changed"
          return nil
        end

        changed = point.fields.reject { |r, c, len, value| now[[r, c, len]] == value }
        changed.each do |r, c, _len, value|
          @session.move_to(r, c)
          @session.press(:erase_eof, wait: false)
          @session.type(value) unless value.empty?
        end
        changed.size
      end

      # An unformatted screen has no fields: rows that differ are typed over
      # (in overtype mode, so nothing shifts).
      def restore_rows(point, screen)
        changed = point.rows.each_index.reject { |r| screen.row_text(r) == point.rows[r] }
        return 0 if changed.empty?

        @session.press(:insert, wait: false) if @insert_mode
        changed.each do |r|
          @session.move_to(r, 0)
          @session.type(point.rows[r])
        end
        @session.press(:insert, wait: false) if @insert_mode
        changed.size
      end
    end
  end
end
