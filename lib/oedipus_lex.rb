require "stringio"
require 'strscan'
require "erb"
require "oedipus_lex.rex"

class OedipusLex
  VERSION = "2.1.0"

  attr_accessor :class_name
  attr_accessor :header
  attr_accessor :ends
  attr_accessor :inners
  attr_accessor :macros
  attr_accessor :option
  attr_accessor :rules
  attr_accessor :starts

  DEFAULTS = {
    :debug    => false,
    :do_parse => false,
    :lineno   => false,
    :stub     => false,
  }

  def initialize opts = {}
    self.option     = DEFAULTS.merge opts
    self.class_name = nil

    self.header  = []
    self.ends    = []
    self.inners  = []
    self.macros  = []
    self.rules   = []
    self.starts  = []
  end

  def lex_class prefix, name
    header.concat prefix.split(/\n/)
    self.class_name = name
  end

  def lex_comment line
    # do nothing
  end

  def lex_end line
    ends << line
  end

  def lex_inner line
    inners << line
  end

  def lex_start line
    starts << line.strip
  end

  def lex_macro name, value
    macros << [name, value]
  end

  def lex_option option
    self.option[option.to_sym] = true
  end

  def lex_rule start_state, regexp, action = nil
    rules << [start_state, regexp, action]
  end

  def lex_rule2(*vals)
    raise vals.inspect
  end

  def lex_state new_state
    # do nothing -- lexer switches state for us
  end

  def generate
    states                 = rules.map(&:first).compact.uniq
    exclusives, inclusives = states.partition { |s| s =~ /^:[A-Z]/ }

    # NOTE: doubling up assignment to remove unused var warnings in
    # ERB binding.

    all_states =
      all_states = [[nil,                        # non-state # eg [[nil,
                     *inclusives],               # incls     #      :a, :b],
                    *exclusives.map { |s| [s] }] # [excls]   #     [:A], [:B]]

    ERB.new(TEMPLATE, nil, "%").result binding
  end

  rule = <<-'END_RULE'.chomp
%         start_state, rule_expr, rule_action = *rule
%         if start_state == state or (state.nil? and predicates.include? start_state) then
%           if start_state and not exclusive then
%             if start_state =~ /^:/ then
                when (state == <%= start_state %>) && (text = ss.scan(<%= rule_expr %>)) then
%             else
                when <%= start_state %> && (text = ss.scan(<%= rule_expr %>)) then
%             end
%           else
                when text = ss.scan(<%= rule_expr %>) then
%           end
%           if rule_action then
%             case rule_action
%             when /^\{/ then
                  action <%= rule_action %>
%             when /^:/, "nil" then
                  [:state, <%= rule_action %>]
%             else
                  <%= rule_action %> text
%             end
%           else
                  # do nothing
%           end
%         end # start_state == state
  END_RULE

  subrule = rule.gsub(/^ /, "   ").sub(/\*rule/, "*subrule")

  TEMPLATE = <<-'REX'.sub(/RULE/, rule).gsub(/^ {6}/, '\1')
      #--
      # This file is automatically generated. Do not modify it.
      # Generated by: oedipus_lex version <%= VERSION %>.
% if filename then
      # Source: <%= filename %>
% end
      #++

% unless header.empty? then
%   header.each do |s|
      <%= s %>
%   end

% end
      class <%= class_name %>
        require 'strscan'

% unless macros.empty? then
%   max = macros.map { |(k,_)| k.size }.max
%   macros.each do |(k,v)|
        <%= "%-#{max}s = %s" % [k, v] %>
%   end

% end
        class ScanError < StandardError ; end

        attr_accessor :lineno
        attr_accessor :filename
        attr_accessor :ss
        attr_accessor :state

        alias :match :ss

        def matches
          m = (1..9).map { |i| ss[i] }
          m.pop until m[-1] or m.empty?
          m
        end

        def action
          yield
        end

% if option[:do_parse] then
        def do_parse
          while token = next_token do
            type, *vals = token

            send "lex_#{type}", *vals
          end
        end

% end
        def scanner_class
          StringScanner
        end unless instance_methods(false).map(&:to_s).include?("scanner_class")

        def parse str
          self.ss     = scanner_class.new str
          self.lineno = 1
          self.state  ||= nil

          do_parse
        end

        def parse_file path
          self.filename = path
          open path do |f|
            parse f.read
          end
        end

        def next_token
% starts.each do |s|
          <%= s %>
% end
% if option[:lineno] then
          self.lineno += 1 if ss.peek(1) == "\n"
% end

          token = nil

          until ss.eos? or token do
            token =
              case state
% all_states.each do |the_states|
%   exclusive = the_states.first != nil
%   all_states, predicates = the_states.partition { |s| s.nil? or s.start_with? ":" }
%   filtered_states = the_states.select { |s| s.nil? or s.start_with? ":" }
              when <%= all_states.map { |s| s || "nil" }.join ", " %> then
                case
%   all_states.each do |state|
%     rules.each do |rule|
RULE
%     end # rules.each
%   end # the_states.each
                else
                  text = ss.string[ss.pos .. -1]
                  raise ScanError, "can not match (#{state.inspect}): '#{text}'"
                end
% end # all_states
              else
                raise ScanError, "undefined state: '#{state}'"
              end # token = case state

            next unless token # allow functions to trigger redo w/ nil
          end # while

          raise "bad lexical result: #{token.inspect}" unless
            token.nil? || (Array === token && token.size >= 2)

          # auto-switch state
          self.state = token.last if token && token.first == :state

% if option[:debug] then
          p [state, token]
% end
          token
        end # def _next_token
% inners.each do |s|
        <%= s %>
% end
      end # class
% unless ends.empty? then

%   ends.each do |s|
        <%= s %>
%   end
% end
% if option[:stub] then

      if __FILE__ == $0
        ARGV.each do |path|
          rex = <%= class_name %>.new

          def rex.do_parse
            while token = self.next_token
              p token
            end
          end

          begin
            rex.parse_file path
          rescue
            $stderr.printf "%s:%d:%s\n", rex.filename, rex.lineno, $!.message
            exit 1
          end
        end
      end
% end
  REX
end

if $0 == __FILE__ then
  ARGV.each do |path|
    rex = OedipusLex.new

    rex.parse_file path
    puts rex.generate
  end
end
