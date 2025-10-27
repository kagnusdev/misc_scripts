#!/usr/bin/env ruby

class BaseTransformer
    def initialize(source)
        @src = source
    end

    attr_reader :src

    def transform
        raise UnimplementedError, 'child class must implement #transform'
    end

    def to_s
        transform
    end
end

class RawLine < BaseTransformer
    def transform
        src
    end
end

class PartyMon
    attr_reader :id
    attr_reader :level
    attr_accessor :moves
    attr_accessor :source_moves

    def initialize(id, level)
        @id = id
        @level = level
        @moves = []
        @source_moves = []
    end

    def defined_moves?
        !moves.empty? || !source_moves.empty?
    end

    def tr_moves
        return unless defined_moves?

        if source_moves.empty?
            "\t\ttr_moves #{moves.join(', ')}"
        elsif moves.empty?
            "\t\ttr_moves #{source_moves.join(', ')}"
        else
            handle_moves_conflict
        end
    end

    private

    def handle_moves_conflict
        lines = ["\t\ttr_moves #{moves.join(', ')}"]
        lines << "\t\ttr_moves #{source_moves.join(', ')}" if moves != source_moves
        lines.join("\n")
    end
end

class AbstractParty
    attr_reader :trainer_class
    attr_reader :id
    attr_reader :level
    attr_reader :mons

    def initialize(trainer_class, id, level)
        @trainer_class = trainer_class
        @id = id
        @level = level
        @mons = []
    end

    def add_mon(line)
        @mons << build_mon(line)
    end

    def add_moves(line)
        @mons.last.source_moves = line[/\t+tr_moves (.*)/, 1].split(',').map(&:strip)
    end

    def transform
        [
            "\tdef_trainer #{id}, #{level}",
            transformed_mons,
            "\tend_trainer",
        ].join("\n")
    end

    private

    def transformed_mons
        mons.map { transform_mon(_1) }.join("\n")
    end

    def transform_mon(mon)
        [
            tr_mon(mon),
            mon.tr_moves,
        ].compact.join("\n")
    end
end

class FlatLevelsParty < AbstractParty
    def initialize(trainer_class, id, level)
        super(trainer_class, id, level.to_i)
    end

    private

    def build_mon(line)
        PartyMon.new(line[/\ttr_mon (.*)/, 1], level)
    end

    def tr_mon(mon)
        "\ttr_mon #{mon.id}"
    end
end

class MultiLevelsParty < AbstractParty
    def initialize(trainer_class, id, _lv)
        super(trainer_class, id, 'TRAINERTYPE_MULTI_LEVELS')
    end

    private

    def build_mon(line)
        lv, id = line.match(/\ttr_mon (\d+), +(.*)/).values_at(1, 2)
        PartyMon.new(id, lv.to_i)
    end

    def tr_mon(mon)
        "\ttr_mon #{mon.level}, #{mon.id}"
    end
end

class PartiesParser
    def initialize(file_path)
        parse_file(file_path)
    end

    def parties
        parts.select { _1.is_a?(AbstractParty) }
    end

    def transform
        parts.map(&:transform).join("\n")
    end

    private

    attr_reader :parts

    def parse_file(file_path)
        @parts = []
        File.readlines(file_path).each do |line|
            parse_line(line.chomp)
        end
    end

    def parse_line(line)
        case line
        when /\tdef_trainer_class /
            @current_class = line[/\tdef_trainer_class (.*)/, 1]
            raw(line)
        when /\tdef_trainer /
            id, level = line.match(/\tdef_trainer +(\d+), +(.*)/).values_at(1, 2)
            @current_party = (level.to_i.zero? ? MultiLevelsParty : FlatLevelsParty).new(@current_class, id.to_i, level)
        when /\ttr_mon /
            @current_party.add_mon(line)
        when /\t+tr_moves /
            @current_party.add_moves(line)
        when /\tend_trainer/
            parts.push(@current_party)
        else
            raw(line)
        end
    end

    def raw(line)
        parts.push(RawLine.new(line))
    end
end

LevelUpMove = Struct.new(:level, :id)

class LevelUpLearnset
    attr_reader :moves

    def initialize(level_up_moves)
        @moves = level_up_moves.sort_by(&:level)
    end

    def teach(level, base_moves)
        current_moves = base_moves.dup
        moves.select { _1.level <= level }.each do |move|
            next if current_moves.include?(move.id)

            current_moves.push(move.id)
            current_moves = current_moves.drop(current_moves.length - 4) if current_moves.length > 4
        end
        current_moves
    end
end

class EvoMoves
    def initialize(file_path, mon_consts:)
        parse_file(file_path)
        @mon_consts = mon_consts
    end

    def learnset(mon)
        index = @mon_consts.offset(mon) - 1
        pointer = @pointers[index]
        @learnsets[pointer]
    end

    private

    def parse_file(file_path)
        @parse_step = :pre_pointers
        @pointers = []
        @learnsets = {}
        File.readlines(file_path).each do |line|
            __send__(:"parse_#{@parse_step}", line.chomp)
        end
        @learnsets[@current_label] = LevelUpLearnset.new(@current_learnset) unless @learnsets.key?(@current_label)
        %i[@parse_step @current_label @current_learnset].each { remove_instance_variable(_1) if instance_variable_defined?(_1) }
    end

    def parse_pre_pointers(line)
        return unless line.start_with?("\ttable_width 2")

        @parse_step = :pointers
    end

    def parse_pointers(line)
        unless line.start_with?("\tdw ")
            @parse_step = :label
            return
        end

        @pointers << line[/\tdw +(.*)/, 1]
    end

    def parse_label(line)
        return unless line.end_with?(':')

        @current_label = line.gsub(':', '')
        @parse_step = :learnset_comment
    end

    def parse_learnset_comment(line)
        return unless line == '; Learnset'

        @parse_step = :learnset
        @current_learnset = []
    end

    def parse_learnset(line)
        return if line == "\tdb 0"
        unless line.start_with?("\tdb ")
            @parse_step = :label
            @learnsets[@current_label] = LevelUpLearnset.new(@current_learnset)
            return
        end

        @current_learnset << build_level_up_move(line)
    end

    def build_level_up_move(line)
        level, move = line.match(/\tdb +(\d+), +(.*)/).values_at(1, 2)
        LevelUpMove.new(level.to_i, move)
    end
end

class BaseLearnset
    attr_reader :moves
    attr_reader :raw_moves

    def initialize(file_path)
        File.readlines(file_path).each do |line|
            next unless line.include?('; level 1 learnset')

            @raw_moves = line[/db (.*) ; level 1 learnset/, 1].split(',').map(&:strip)
        end
        @moves = @raw_moves.reject { _1 == 'NO_MOVE' }
    end
end

class BaseStats
    def initialize(root_dir, file_subpath, dex_order:)
        read_files_list(File.join(root_dir, file_subpath))
        @root_dir = root_dir
        @dex_order = dex_order
        @learnsets = Hash.new { |h, mon| h[mon] = build_learnset(mon) }
    end

    def learnset(mon)
        @learnsets[mon].moves
    end

    private

    def build_learnset(mon)
        # binding.irb
        BaseLearnset.new(File.join(@root_dir, @files_list[@dex_order.mon_to_dex_offset(mon)]))
    end

    def read_files_list(file_path)
        @files_list = []
        File.readlines(file_path).each do |line|
            next unless line.start_with?('INCLUDE "')
            @files_list << line[/INCLUDE "(.*)"/, 1]
        end
    end
end

class DexOrder
    def initialize(file_path, dex_consts:, mon_consts:)
        read_data(file_path)
        @dex_consts = dex_consts
        @mon_consts = mon_consts
    end

    def mon_to_dex(mon)
        @data[@mon_consts.offset(mon) - 1]
    end

    def mon_to_dex_offset(mon)
        @dex_consts.offset(mon_to_dex(mon))
    end

    private

    def read_data(file_path)
        @data = []
        File.readlines(file_path).each do |line|
            next unless line.start_with?("\tdb ")
            line.chomp!
            @data << line[/\tdb +(\S*)/, 1]
        end
    end
end

class ConstParser
    def initialize(file_path, const_macro: 'const')
        read_consts(file_path, const_macro)
    end

    def offset(val)
        @consts.index(val)
    end

    def value(val)
        offset(val)&.+ @base_const
    end

    def at(idx)
        @consts[idx]
    end

    def value_at(idx)
        at(idx)&.+ @base_const
    end

    private

    def read_consts(file_path, const_macro)
        @consts = []
        File.readlines(file_path).each do |line|
            next unless line.start_with?("\tconst_def", "\t#{const_macro}")
            line.chomp!
            if line.start_with?("\tconst_def")
                @base_const = line[/\tconst_def *(.*)/, 1].to_i
            else
                @consts << line[/\t#{const_macro} *(\S+)/, 1]
            end
        end
    end
end

MoveOverride = Struct.new(:slot, :id)

MovesOverride = Struct.new(:mon_index, :moves)

class TeamMovesOverride
    attr_reader :trainer_class
    attr_reader :trainer_id
    attr_reader :overrides

    def initialize(lines)
        trainer_data, *team_data = lines
        @trainer_class, tid = trainer_data.match(/\tdb +(.+), +(\d+)/).values_at(1, 2)
        @trainer_id = tid.to_i
        team_data.map! { |line| line.match(/\tdb +(\d+), +(\d+), +(.+)/).values_at(1, 2, 3) }
        @overrides = team_data.group_by(&:first).map { |group| extract_moves_override(group) }
    end

    private

    def extract_moves_override(data)
        MovesOverride.new(data.first.to_i, data.last.map { |(_mon, slot, id)| MoveOverride.new(slot.to_i, id) })
    end
end

class SpecialMoves
    attr_reader :team_overrides

    def initialize(file_path)
        @team_overrides = parse(file_path)
    end

    private

    def parse(file_path)
        teams = []
        team_buffer = []
        File.readlines(file_path).each do |line|
            line.chomp!
            next unless line.start_with?("\tdb ")
            next if line.start_with?("\tdb -1")

            if line != "\tdb 0"
                team_buffer << line
            else
                teams << TeamMovesOverride.new(team_buffer)
                team_buffer = []
            end
        end
        teams
    end
end

class MovesInserter
    attr_reader :teams
    attr_reader :team_overrides

    def initialize(team_overrides, teams, base_stats:, evos_moves:)
        @teams = teams
        @team_overrides = team_overrides
        @base_stats = base_stats
        @evos_moves = evos_moves
    end

    def process!
        team_overrides.each do |t_o|
            team = team_for(t_o)
            next unless team
            apply_to_team!(t_o, team)
        end
    end

    private

    def team_for(t_o)
        teams.find { _1.trainer_class == t_o.trainer_class && _1.id == t_o.trainer_id }
    end

    def apply_to_team!(t_o, team)
        fill_team_moves!(team)
        t_o.overrides.each do |overrides|
            apply_to_mon!(overrides.moves, team.mons[overrides.mon_index - 1])
        end
    end

    def apply_to_mon!(moves, mon)
        moves.each { mon.moves[_1.slot - 1] = _1.id }
    end

    def fill_team_moves!(team)
        team.mons.each { fill_mon_moves!(_1) }
    end

    def fill_mon_moves!(mon)
        return unless mon.moves.empty?

        mon.moves = @evos_moves.learnset(mon.id).teach(mon.level, @base_stats.learnset(mon.id))
    end
end

class PokeYellow
    attr_reader :root_dir
    attr_reader :dex_order
    attr_reader :base_stats
    attr_reader :evos_moves
    attr_reader :parties_parser
    attr_reader :parties_file_path

    def initialize(root_dir)
        @root_dir = root_dir
        @parties_file_path = File.join(root_dir, 'data/trainers/parties.asm')
    end

    def valid_root_dir?
        File.read(File.join(root_dir, 'roms.sha1')).include?('cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1 *pokeyellow.gbc')
    end

    def parse!
        @special_moves = SpecialMoves.new(File.join(root_dir, 'data/trainers/special_moves.asm'))
        @mon_consts = ConstParser.new(File.join(root_dir, 'constants/pokemon_constants.asm'))
        @dex_consts = ConstParser.new(File.join(root_dir, 'constants/pokedex_constants.asm'))
        @trainer_consts = ConstParser.new(File.join(root_dir, 'constants/trainer_constants.asm'), const_macro: 'trainer_const')
        @dex_order = DexOrder.new(File.join(root_dir, 'data/pokemon/dex_order.asm'), dex_consts: @dex_consts, mon_consts: @mon_consts)
        @base_stats = BaseStats.new(root_dir, 'data/pokemon/base_stats.asm', dex_order: @dex_order)
        @evos_moves = EvoMoves.new(File.join(root_dir, 'data/pokemon/evos_moves.asm'), mon_consts: @mon_consts)
        @parties_parser = PartiesParser.new(parties_file_path)
    end

    def insert_special_moves!
        MovesInserter.new(@special_moves.team_overrides, @parties_parser.parties, base_stats: @base_stats, evos_moves: @evos_moves).process!
    end
end

options = {
    dry_run: true,
    debug: false,
    bypass_dir_check: false,
}

require 'optparse'

OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [--skip-check] [--rewrite] <path/to/pokeyellow"

    opts.on '--rewrite', 'write transformation to file instead of displaying it' do
        options[:dry_run] = false
    end

    opts.on '--skip-check', "skips root directory check (useful for pokered repos that implemented yellow's special moves or if you modified roms.sha1)" do
        options[:bypass_dir_check] = true
    end

    opts.on '--debug', 'enable binding.irb on error' do
        options[:debug] = true
    end
end.parse!

pokeyellow_root_dir = ARGV.first

manager = PokeYellow.new(pokeyellow_root_dir)
raise ArgumentError, "invalid pokeyellow directory '#{pokeyellow_root_dir}'" unless options[:bypass_dir_check] || manager.valid_root_dir?

manager.parse!
manager.insert_special_moves!

transformed = manager.parties_parser.transform

if options[:dry_run]
    puts transformed
else
    File.open(manager.parties_file_path, 'w') { |f| f.puts transformed }
    puts "wrote macros into #{manager.parties_file_path}"
end