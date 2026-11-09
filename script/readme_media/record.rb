# Builds the README's screenshot and GIF without touching the desktop: runs
# ruby3270 against the built-in fake host, drives it from inside (no simulated
# keys), and records what each frame draws. render.py then redraws those
# frames with Pillow (Direct2D output can't be screen-captured reliably).
#
#   ruby script/readme_media/record.rb OUT_DIR
#   python script/readme_media/render.py 1.5 docs/images/main-window.png OUT_DIR/main.json
#   python script/readme_media/render.py 0.8 docs/images/snippet-search.gif $(cat OUT_DIR/frames.txt)
#
# Run it with HOME / USERPROFILE set to a copy of script/demo_home, so your own
# settings aren't used or changed (it uses port 3290 for the fake host).
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "tn3270"; require "tn3270/fake_host"; require "tn3270/gui/program"
require "json"
module PainterRecorder2
  def context=(ctx)
    @ops = [] if @recording_next
    @recording_next = false
    super
  end
  def record! = (@recording_next = true)
  def ops = @ops
  %i[fill_rect stroke_rect fill_circle stroke_circle polyline].each do |m|
    define_method(m) do |*args, **kw|
      @ops&.push([m.to_s, *args])
      super(*args, **kw)
    end
  end
  def text(x, y, width, str, rgb, family, size, bold: false, align: :left, alpha: 1.0)
    @ops&.push(["text", x, y, width, str, rgb, size, bold, align.to_s, alpha, family.to_s])
    super
  end
end
Tn3270::Gui::Painter.prepend(PainterRecorder2)
OUT = ARGV[0]
HOST = Tn3270::FakeHost.new(port: 3290, log: nil).start
$frames = []

class Media < Tn3270::Gui::Program
  def w = @windows.first
  def tab = w.instance_variable_get(:@tab)
  def text = tab.controller.screen_text.to_s
  def picker = w.instance_variable_get(:@picker)

  # Each step: [condition or seconds to wait first, action]
  def steps
    @steps ||= [
      [-> { text.include?("USER ID") }, -> {}],
      [0.3, -> { tab.controller.type("user01"); tab.controller.press(:enter) }],
      [-> { text.include?("MAIN MENU") }, -> { w.command(:duplicate_tab, tab) }],
      [-> { w.tabs.last.controller.screen_text.to_s.include?("USER ID") }, -> { w.command(:select_tab, w.tabs.first) }],
      [0.3, -> { for_all(:toggle_snippet_bar, true) }],
      [1.5, -> { shot("main") }],
      [0.5, -> { for_all(:toggle_snippet_bar, false); w.command(:select_tab, w.tabs.last) }],
      [1.5, -> { shot("f00", 1200) }],
      [0.2, -> { w.command(:open_picker); shot("f01", 1100) }],
      *"sign".chars.each_with_index.map { |c, i| [0.2, -> { picker[:query] << c; picker[:sel] = 0; shot("f0#{2 + i}", i == 3 ? 1400 : 220) }] },
      [0.2, -> { w.command(:pick, w.command(:picker_items).first) }],
      [-> { text.include?("MAIN MENU") }, -> {}],
      [0.4, -> { shot("f06", 1600) }],
      [0.2, -> { w.command(:open_picker); shot("f07", 700) }],
      *"caps".chars.each_with_index.map { |c, i| [0.2, -> { picker[:query] << c; picker[:sel] = 0; shot("f0#{8 + i}", i == 3 ? 1500 : 220) }] },
      [0.2, -> { w.command(:pick, w.command(:picker_items).first) }],
      [0.5, -> { shot("f12", 2200) }],
      [0.5, -> { for_all(:set_caps, false) }],
      [0.5, -> { Tn3270::Gui::UI.quit }]
    ]
  end

  def shot(name, ms = nil)
    pt = w.instance_variable_get(:@painter)
    pt.record!
    w.command(:redraw)
    @pending = [name, ms, pt, 3]
  end

  def pump
    super
    if @pending
      name, ms, pt, left = @pending
      if (left -= 1).positive?
        @pending[3] = left
        return
      end
      path = File.join(OUT, "#{name}.json")
      File.write(path, JSON.generate("size" => w.instance_variable_get(:@area_size), "ops" => pt.ops || []))
      $frames << [path, ms] if ms
      puts "#{name}: #{pt.ops&.size} ops"
      @pending = nil
    end
    @at ||= Time.now
    return if steps.empty?

    cond, action = steps.first
    ready = cond.is_a?(Proc) ? cond.call : Time.now - @at >= cond
    if Time.now - @at > 20
      puts "stuck at step #{@done.to_i}"
      return Tn3270::Gui::UI.quit
    end
    return unless ready

    action.call
    steps.shift
    @done = @done.to_i + 1
    @at = Time.now
  end
end
Media.new(session: "Demo LPAR").run
HOST.stop
File.write(File.join(OUT, "frames.txt"), $frames.map { |p, ms| "#{p}:#{ms}" }.join("\n"))
