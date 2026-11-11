# frozen_string_literal: true

require "fiddle"
require_relative "config"

module Tn3270
  module Gui
    # The spell checker built into Windows 8 and later (the one Edge and
    # Notepad use), called through COM with Fiddle: nothing to install.
    #
    #   checker = SpellChecker.open("en-US")   # nil if unavailable
    #   checker.correct?("teh")                # => false
    #   checker.suggest("teh")                 # => ["the", "ten", ...]
    #   checker.add("JCL")                     # your Windows dictionary
    #
    # COM objects belong to the thread that made them: use a checker only on
    # the thread that opened it (the GUI's main thread).
    class SpellChecker
      CLSID_FACTORY = "7AB36653-1796-484B-BDFA-E74F1DB7C1DC"
      IID_FACTORY = "8E018A9D-2415-4677-BF08-794EA61F94BB"
      CLSCTX_INPROC_SERVER = 1
      COINIT_APARTMENTTHREADED = 2
      S_OK = 0

      P = Fiddle::TYPE_VOIDP
      I = Fiddle::TYPE_INT
      U = Fiddle::TYPE_UINTPTR_T

      # vtable slots (IUnknown takes 0-2)
      RELEASE = 2
      FACTORY_LANGUAGES = 3 # ISpellCheckerFactory::get_SupportedLanguages
      FACTORY_SUPPORTED = 4 #   ::IsSupported
      FACTORY_CREATE = 5    #   ::CreateSpellChecker
      CHECK = 4             # ISpellChecker::Check
      SUGGEST = 5           #   ::Suggest
      ADD = 6               #   ::Add
      ENUM_NEXT = 3         # IEnumSpellingError::Next / IEnumString::Next

      class << self
        # A checker for `language` ("en-US"; nil = the Windows display
        # language, falling back to en-US). nil when Windows has none.
        def open(language = nil)
          return nil unless Config::WINDOWS

          factory = self.factory
          return nil unless factory

          tag = [language, user_language, "en-US"].compact.find { |t| supported?(factory, t) }
          return nil unless tag

          out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
          return nil unless com(factory, FACTORY_CREATE, [P, P], wide(tag), out) == S_OK

          new(out.ptr, tag)
        rescue Fiddle::DLError, StandardError
          nil
        end

        # Language tags Windows can spell check ("en-US", "fr-FR", ...).
        def languages
          factory = self.factory
          return [] unless factory

          out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
          return [] unless com(factory, FACTORY_LANGUAGES, [P], out) == S_OK

          strings(out.ptr).sort
        rescue Fiddle::DLError, StandardError
          []
        end

        def factory
          return @factory if defined?(@factory)

          ole32_fn("CoInitializeEx", [P, I]).call(nil, COINIT_APARTMENTTHREADED)
          out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
          hr = ole32_fn("CoCreateInstance", [P, P, I, P, P]).call(
            guid(CLSID_FACTORY), nil, CLSCTX_INPROC_SERVER, guid(IID_FACTORY), out
          )
          @factory = hr == S_OK ? out.ptr : nil
        rescue Fiddle::DLError
          @factory = nil
        end

        def supported?(factory, tag)
          ok = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
          com(factory, FACTORY_SUPPORTED, [P, P], wide(tag), ok) == S_OK && ok[0, 4].unpack1("l") != 0
        end

        def user_language
          buf = Fiddle::Pointer.malloc(170, Fiddle::RUBY_FREE)
          len = Fiddle::Function.new(dll("kernel32")["GetUserDefaultLocaleName"], [P, I], I).call(buf, 85)
          len.positive? ? buf[0, (len - 1) * 2].force_encoding("UTF-16LE").encode("UTF-8") : nil
        end

        # ---- COM plumbing ----------------------------------------------------

        # Calls vtable slot `index` of a COM object; returns the HRESULT.
        def com(obj, index, types, *args)
          vtable = Fiddle::Pointer.new(obj.to_i).ptr
          fn = Fiddle::Pointer.new(vtable.to_i + (index * Fiddle::SIZEOF_VOIDP)).ptr
          Fiddle::Function.new(fn.to_i, [P, *types], I).call(obj, *args)
        end

        def release(obj) = obj.to_i.zero? ? nil : com(obj, RELEASE, [])

        # Reads every string from an IEnumString and releases it.
        def strings(enum)
          result = []
          item = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
          fetched = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
          while com(enum, ENUM_NEXT, [I, P, P], 1, item, fetched) == S_OK
            ptr = item.ptr
            result << read_wide(ptr)
            ole32_fn("CoTaskMemFree", [P], Fiddle::TYPE_VOID).call(ptr)
          end
          result
        ensure
          release(enum) if enum
        end

        def read_wide(ptr)
          len = Fiddle::Function.new(dll("kernel32")["lstrlenW"], [P], I).call(ptr)
          ptr[0, len * 2].force_encoding("UTF-16LE").encode("UTF-8")
        end

        def wide(str) = Fiddle::Pointer["#{str}\0".encode("UTF-16LE")]

        # "7AB36653-1796-..." -> the 16-byte GUID struct
        def guid(text)
          hex = text.delete("-")
          Fiddle::Pointer[[hex[0, 8].to_i(16), hex[8, 4].to_i(16), hex[12, 4].to_i(16)].pack("L<S<S<") + [hex[16, 16]].pack("H*")]
        end

        def dll(name)
          @dlls ||= {}
          @dlls[name] ||= Fiddle.dlopen(name)
        end

        def ole32_fn(name, args, ret = I)
          @ole_fns ||= {}
          @ole_fns[name] ||= Fiddle::Function.new(dll("ole32")[name], args, ret)
        end
      end

      attr_reader :language

      def initialize(com_object, language)
        @obj = com_object
        @language = language
      end

      # Whether Windows knows the word (Windows' own ignore and dictionary
      # lists included).
      def correct?(word)
        out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
        return true unless self.class.com(@obj, CHECK, [P, P], self.class.wide(word), out) == S_OK

        enum = out.ptr
        err = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
        found = self.class.com(enum, ENUM_NEXT, [P], err) == S_OK
        self.class.release(err.ptr) if found
        self.class.release(enum)
        !found
      end

      def suggest(word)
        out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
        return [] unless self.class.com(@obj, SUGGEST, [P, P], self.class.wide(word), out) >= 0

        self.class.strings(out.ptr) - [word]
      end

      # Adds the word to the Windows user dictionary (shared with other apps).
      def add(word) = self.class.com(@obj, ADD, [P], self.class.wide(word)) == S_OK
    end
  end
end
