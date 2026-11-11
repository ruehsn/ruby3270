# frozen_string_literal: true

module Tn3270
  module Gui
    # Where each line of a multi-line paste goes. Lines line up under the
    # column the paste started in, one row down each, the way an editor such
    # as ISPF EDIT expects:
    #
    #   000100 //APPCIN  JOB ...     a paste at the cursor (column 8 here)
    #   000200 //        TIME=...    puts line 2 in column 8 of the next row,
    #                                not in the next field (the line number)
    #
    # A row with no input field at that column (a form, say USER ID with
    # PASSWORD two rows down) gets the line in the next input field below
    # instead. Each line is cut at the end of its field, so it never spills
    # into the next field, and nothing wraps past the bottom of the screen.
    module Paste
      # Returns [steps, note]: steps are [:move, row, col] and [:type, text];
      # note is a status-bar message when lines were cut or left out.
      def self.plan(screen, row, col, lines)
        steps = []
        cut = 0
        done = 0
        current = row
        lines.each_with_index do |line, i|
          line = line.tr("\t", " ")
          if i.positive?
            target = target_for(screen, current, col) or break
            current, c = target
            steps << [:move, current, c]
          else
            c = col
          end
          room = room_at(screen, current, c)
          if room && line.size > room
            line = line[0, room]
            cut += 1
          end
          steps << [:type, line] unless line.empty?
          done += 1
        end
        [steps, note(lines.size, done, cut)]
      end

      # Where the line after the one on `row` goes: same column on the next
      # row when that's an input position, otherwise the next input field
      # below. nil when there is none (the bottom of the screen).
      def self.target_for(screen, row, col)
        below = row + 1
        return nil if below >= screen.rows
        return [below, col] if screen.fields.empty? # unformatted: type anywhere

        field = screen.field_at(below, col)
        return [below, col] if field&.input?

        first = below * screen.cols
        nxt = screen.input_fields.find { |f| (f.row * screen.cols) + f.col >= first && f.length.positive? }
        nxt && [nxt.row, nxt.col]
      end

      # Characters left in the field from (row, col) to its end; for an
      # unformatted screen, to the end of the row. nil: no limit known.
      def self.room_at(screen, row, col)
        return screen.cols - col if screen.fields.empty?

        field = screen.field_at(row, col)
        return nil unless field&.input?

        (field.row * screen.cols) + field.col + field.length - ((row * screen.cols) + col)
      end

      def self.note(total, done, cut)
        return nil if total < 2 && cut.zero?

        parts = []
        parts << "pasted #{done} of #{total} lines (no room below)" if done < total
        parts << "#{cut} line#{'s' unless cut == 1} cut to fit the field" if cut.positive?
        return nil if parts.empty?

        parts.join("; ").sub(/\A./, &:upcase)
      end
    end
  end
end
