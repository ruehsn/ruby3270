# frozen_string_literal: true

require_relative "ui"
require_relative "dialogs"
require_relative "snippet_library"
require_relative "../snippet"

module Tn3270
  module Gui
    TOKEN_HELP = "Keys: {Enter} {PF1}-{PF24} {PA1}-{PA3} {Clear} {Tab} {Reset} {EraseEOF} {Attn} {SysReq}\n" \
                 "Wait: {wait:READY}    Ask when run: {ask:Job name}    Fill in: {date} {date:%y%m%d} {time} {user} {clipboard}\n" \
                 "A new line moves to the next input field (unless the line ended with a key). {{ types a {."

    # Snippets sidebar > New / Edit: a snippet's name, text, and which file it lives in.
    class SnippetEditor
      include DialogSupport

      def initialize(library, item, text: nil, name: nil, on_saved:)
        @library = library
        # A snippet from a file you can't change: edit a copy, saved as your own.
        @copy_of = item if item && !library.writable?(item.file)
        @item = @copy_of ? nil : item
        @text = item ? item.text : text.to_s
        @name_text = item ? item.name : name.to_s
        @on_saved = on_saved
        @warned = nil
      end

      def show
        @win = Ui.window(@item || @copy_of ? "Edit Snippet" : "New Snippet", 640, 460)
        UI.window_on_closing(@win) { 1 }
        box = Ui.vbox
        form = Ui.form
        @name = Ui.form_row(form, "Name", Ui.entry(@name_text))
        @files = @library.writable_files
        @files |= [@item.file] if @item && !@files.include?(@item.file)
        labels = @files.map { |f| file_label(f) }
        selected = [@files.index(@item&.file || @library.personal_file) || 0, 0].max
        @file = Ui.form_row(form, "Save in", Ui.combobox(labels, selected: selected))
        Ui.add(box, form)
        if @copy_of
          Ui.add(box, Ui.label("\"#{@copy_of.name}\" is in a shared file you can't change " \
                               "(#{File.basename(@copy_of.file)}). Saving makes your own copy."))
        end
        Ui.add(box, Ui.label("Text to type:"))
        @body = Ui.keep(UI.new_non_wrapping_multiline_entry)
        UI.multiline_entry_set_text(@body, @text)
        Ui.add(box, @body, stretchy: true)
        Ui.add(box, Ui.label(TOKEN_HELP))
        @error = Ui.add(box, Ui.label(""))
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("Save") { save })
        Ui.add(row, Ui.button("Cancel") { close_window(@win) })
        UI.window_set_child(@win, box)
        show_window(@win)
        Win32.focus_control(@name)
      end

      private

      def file_label(file)
        file == @library.personal_file ? "My snippets  (#{file})" : "#{File.basename(file)}  (#{File.dirname(file)})"
      end

      def save
        name = Ui.entry_text(@name).strip
        text = Ui.take_text(UI.multiline_entry_text(@body)).delete("\r")
        file = @files[UI.combobox_selected(@file)]
        return UI.label_set_text(@error, "Give the snippet a name.") if name.empty?
        return UI.label_set_text(@error, "Type the text the snippet should type.") if text.strip.empty?
        return UI.label_set_text(@error, "Can't write to #{file}.") unless file && @library.writable?(file)

        unknown = Snippet.unknown_tokens(text).uniq
        if unknown.any? && @warned != unknown
          @warned = unknown
          return UI.label_set_text(@error, "Not keys I know: #{unknown.join(' ')}. They'd be typed as they are. Click Save again to keep them.")
        end
        @library.save(@item, name, text, file)
        @on_saved.call
        close_window(@win)
      rescue SystemCallError => e
        UI.label_set_text(@error, "Couldn't save: #{e.message}")
      end
    end

    # Asks for the {ask:...} values of a snippet before it runs.
    class AskDialog
      include DialogSupport

      def initialize(name, prompts, on_run:)
        @name = name
        @prompts = prompts
        @on_run = on_run
      end

      def show
        @win = Ui.window("Snippet: #{@name}", 420, 60 + (@prompts.size * 36))
        UI.window_on_closing(@win) { 1 }
        box = Ui.vbox
        form = Ui.form
        @entries = @prompts.map { |p| Ui.form_row(form, p, Ui.entry) }
        Ui.add(box, form)
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("Run") { run })
        Ui.add(row, Ui.button("Cancel") { close_window(@win) })
        UI.window_set_child(@win, box)
        show_window(@win)
        Win32.focus_control(@entries.first)
      end

      private

      def run
        answers = @prompts.zip(@entries).to_h { |p, e| [p, Ui.entry_text(e)] }
        close_window(@win)
        @on_run.call(answers)
      end
    end

    # Snippets sidebar > Files: your own snippet file plus shared files and
    # folders (e.g. a team file on a network drive).
    class SnippetFilesDialog
      include DialogSupport

      def initialize(library, on_change:)
        @library = library
        @on_change = on_change
      end

      def show
        @win = Ui.window("Snippet Files", 720, 380)
        UI.window_on_closing(@win) { 1 }
        box = Ui.vbox
        Ui.add(box, Ui.label("Snippets come from your own file and any shared files or folders listed here.\n" \
                             "A folder means every .yml file in it. Files you can't write to are read-only.\n" \
                             "A script folder lists its scripts (.rb, .ps1, .bat, .py...) too: picking one runs it on the session.\n" \
                             "The comments at the top of a script give its name and description (see the README)."))
        @table = Ui::Table.new(["File", "Kind", "Snippets", "Changes"], rows)
        Ui.add(box, @table.control, stretchy: true)
        @status = Ui.add(box, Ui.label(@library.errors.join("\n")))
        row = Ui.add(box, Ui.hbox)
        Ui.add(row, Ui.button("Add File...") { add_path(Ui.open_file(@win)) })
        Ui.add(row, Ui.button("Add Folder...") { add_path(Ui.take_text(UI.open_folder(@win)).then { |p| p.empty? ? nil : p }) })
        Ui.add(row, Ui.button("Add Script Folder...") { add_script_folder(Ui.take_text(UI.open_folder(@win))) })
        Ui.add(row, Ui.button("New Shared File...") { new_file })
        Ui.add(row, Ui.button("Remove") { remove })
        Ui.add(row, Ui.label(""), stretchy: true)
        Ui.add(row, Ui.button("Close") { close_window(@win) })
        UI.window_set_child(@win, box)
        show_window(@win)
        @table.column_width(0, 420)
      end

      private

      # One row per configured entry: your file, then each shared file or folder.
      def rows
        counts = @library.items.group_by(&:file).transform_values(&:size)
        entries = [[@library.personal_file, "yours"]] + @library.shared_entries.map { |e| [File.expand_path(e), "shared"] }
        @paths = entries.map(&:first)
        entries.map do |path, kind|
          files = File.directory?(path) ? Dir.glob(File.join(path, "*.{yml,yaml}")) : [path]
          count = files.sum { |f| counts[f].to_i }
          kind = "#{kind} folder" if File.directory?(path)
          state = if !File.exist?(path) then kind == "yours" ? "created when you save one" : "missing"
                  elsif files.all? { |f| @library.writable?(f) } then "can change"
                  else "read-only"
                  end
          [path, kind, count.to_s, state]
        end + script_rows
      end

      def script_rows
        scripts = @library.items.select(&:script?)
        @library.script_folders.map do |entry|
          dir = File.expand_path(entry)
          @paths << dir
          count = scripts.count { |i| File.dirname(i.script) == dir }
          [dir, "script folder", count.to_s, File.directory?(dir) ? "scripts run on the session" : "missing"]
        end
      end

      def add_script_folder(path)
        return if path.empty?

        @library.add_script_folder(path.tr("\\", "/"))
        refresh
        UI.label_set_text(@status, "Scripts can run once the session reconnects (it opens the script port then).") \
          if @library.script_folders.size == 1
      end

      def refresh
        @library.reload_if_changed
        @table.rows = rows
        UI.label_set_text(@status, @library.errors.join("\n"))
        @on_change.call
      end

      def add_path(path)
        return unless path

        @library.add_shared(path.tr("\\", "/"))
        refresh
      end

      def new_file
        path = Ui.take_text(UI.save_file(@win))
        return if path.empty?

        path += ".yml" unless path.match?(/\.ya?ml\z/i)
        SnippetLibrary.create_file(path)
        add_path(path)
      end

      def remove
        index = @table.selected
        return UI.label_set_text(@status, "Pick a shared file or folder to remove.") unless index
        return UI.label_set_text(@status, "Your own snippet file can't be removed.") if index.zero?

        shared = @library.shared_entries
        if index <= shared.size
          @library.remove_shared(shared[index - 1])
        else
          @library.remove_script_folder(@library.script_folders[index - 1 - shared.size])
        end
        refresh
      end
    end
  end
end
