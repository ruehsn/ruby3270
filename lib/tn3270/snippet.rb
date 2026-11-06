# frozen_string_literal: true

module Tn3270
  # Snippets: text to type, with keys and placeholders in braces.
  #
  #   =3.4{Enter}
  #   USER01.JCL.*{Enter}
  #   {wait:DSLIST}{PF8}
  #
  # Each new line moves to the next input field (like pasting), unless the
  # line before ended with a key or a {wait:...}: then the key did the moving.
  #
  # Tokens (any case):
  #   {Enter} {Clear} {Tab} {BackTab} {Home} {NewLine} {Reset} {EraseEOF}
  #   {EraseInput} {Attn} {SysReq} {Up} {Down} {Left} {Right} {Delete}
  #   {Backspace} {Insert} {PF1}..{PF24} {PA1}..{PA3}
  #                     press the key; Enter, PF, PA, Clear... wait for the host
  #   {wait:TEXT}       wait until TEXT is on the screen
  #   {ask:Question}    asks for a value when the snippet runs
  #   {date} {date:%y%m%d} {time} {time:%H%M} {user} {clipboard}
  #   {{                a literal {
  module Snippet
    KEYS = {
      "enter" => :enter, "clear" => :clear, "tab" => :tab, "backtab" => :backtab, "home" => :home,
      "newline" => :newline, "reset" => :reset, "eraseeof" => :erase_eof, "erase_eof" => :erase_eof,
      "eraseinput" => :erase_input, "erase_input" => :erase_input, "attn" => :attn, "sysreq" => :sysreq,
      "up" => :up, "down" => :down, "left" => :left, "right" => :right, "delete" => :delete,
      "backspace" => :backspace, "insert" => :insert
    }.freeze
    VARS = %w[date time user clipboard].freeze
    TOKEN = /\{\{|\{([^{}\n]*)\}|[^{]+|\{/

    # A parsed piece: [:text, "abc"], [:key, :enter], [:wait, "READY"],
    # [:ask, "Job name"], [:var, "date", "%y%m%d"].
    module_function

    def parse(text)
      steps = []
      text.to_s.delete("\r").sub(/\n+\z/, "").split("\n", -1).each_with_index do |line, i|
        steps << [:key, :newline] if i.positive? && !moved?(steps.last)
        line.scan(TOKEN) { steps << token(Regexp.last_match) }
      end
      steps
    end

    # The questions {ask:...} will ask, each once, in order.
    def prompts(text) = parse(text).filter_map { |kind, value| value if kind == :ask }.uniq

    # Tokens that aren't keys or placeholders (typed as they are): for a
    # warning when a snippet is saved.
    def unknown_tokens(text) = parse(text).filter_map { |kind, value, raw| raw if kind == :text && raw }

    # Types the snippet into a session.
    #   answers: { "Job name" => "MYJOB" } for {ask:...}
    #   vars:    { clipboard: "...", user: "..." } (date and time are worked out)
    #   press:   how to press a key (default session.press, which waits for the host)
    #   after:   called after each step (the window uses it to redraw)
    def run(session, text, answers: {}, vars: {}, wait_timeout: 30, press: nil, after: nil)
      press ||= ->(key) { session.press(key) }
      expand(parse(text), answers, vars).each do |kind, value|
        case kind
        when :text then session.type(value) unless value.empty?
        when :key then press.call(value)
        when :wait then session.wait_for_text(value, timeout: wait_timeout)
        end
        after&.call
      end
      session
    end

    # Replaces {ask:...} and {date}-style placeholders with text to type.
    # A value with line breaks moves on to the next fields, like a paste.
    def expand(steps, answers, vars)
      steps.flat_map do |kind, value, format|
        case kind
        when :ask then text_steps(answers.fetch(value) { answers.fetch(value.to_sym, "") }.to_s)
        when :var then text_steps(var_value(value, format, vars))
        else [[kind, value]]
        end
      end
    end

    def var_value(name, format, vars)
      case name
      when "date" then Time.now.strftime(format || "%Y-%m-%d")
      when "time" then Time.now.strftime(format || "%H:%M:%S")
      when "user" then (vars[:user] || ENV["USERNAME"] || ENV["USER"]).to_s
      when "clipboard" then vars[:clipboard].to_s.delete("\r").chomp
      end
    end

    def text_steps(value)
      value.split("\n", -1).each_with_index.flat_map do |part, i|
        (i.positive? ? [[:key, :newline]] : []) + [[:text, part]]
      end
    end

    # Did this step already move off the line (a key, or a wait for the host)?
    def moved?(step) = step && %i[key wait].include?(step[0])

    def token(match)
      raw = match[0]
      return [:text, "{"] if raw == "{{"
      return [:text, raw] if match[1].nil? # plain text, or a lone {

      name, arg = match[1].strip.split(":", 2)
      down = name.to_s.downcase
      if (key = KEYS[down]) then [:key, key]
      elsif (m = down.match(/\Apf(\d{1,2})\z/)) && m[1].to_i.between?(1, 24) then [:key, :"pf#{m[1].to_i}"]
      elsif (m = down.match(/\Apa([1-3])\z/)) then [:key, :"pa#{m[1]}"]
      elsif down == "wait" && arg then [:wait, arg]
      elsif down == "ask" && arg then [:ask, arg.strip]
      elsif VARS.include?(down) then [:var, down, arg]
      else [:text, raw, raw] # unknown: typed as written (third element marks it)
      end
    end
  end
end
