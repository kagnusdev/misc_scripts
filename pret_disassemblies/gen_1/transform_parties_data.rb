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

class TrainerGroupLabel < BaseTransformer
    GROUP_TO_CLASS = {
        ''                  => 'NOBODY',         # $00
        'YoungsterData'     => 'YOUNGSTER',      # $01
        'BugCatcherData'    => 'BUG_CATCHER',    # $02
        'LassData'          => 'LASS',           # $03
        'SailorData'        => 'SAILOR',         # $04
        'JrTrainerMData'    => 'JR_TRAINER_M',   # $05
        'JrTrainerFData'    => 'JR_TRAINER_F',   # $06
        'PokemaniacData'    => 'POKEMANIAC',     # $07
        'SuperNerdData'     => 'SUPER_NERD',     # $08
        'HikerData'         => 'HIKER',          # $09
        'BikerData'         => 'BIKER',          # $0A
        'BurglarData'       => 'BURGLAR',        # $0B
        'EngineerData'      => 'ENGINEER',       # $0C
        'UnusedJugglerData' => 'UNUSED_JUGGLER', # $0D
        'RivalF1Data'       => 'RIVAL_F1',       # $0D
        'FisherData'        => 'FISHER',         # $0E
        'SwimmerData'       => 'SWIMMER',        # $0F
        'CueBallData'       => 'CUE_BALL',       # $10
        'GamblerData'       => 'GAMBLER',        # $11
        'BeautyData'        => 'BEAUTY',         # $12
        'PsychicData'       => 'PSYCHIC_TR',     # $13
        'RockerData'        => 'ROCKER',         # $14
        'JugglerData'       => 'JUGGLER',        # $15
        'TamerData'         => 'TAMER',          # $16
        'BirdKeeperData'    => 'BIRD_KEEPER',    # $17
        'BlackbeltData'     => 'BLACKBELT',      # $18
        'Rival1Data'        => 'RIVAL1',         # $19
        'ProfOakData'       => 'PROF_OAK',       # $1A
        'ChiefData'         => 'CHIEF',          # $1B
        'ScientistData'     => 'SCIENTIST',      # $1C
        'GiovanniData'      => 'GIOVANNI',       # $1D
        'RocketData'        => 'ROCKET',         # $1E
        'CooltrainerMData'  => 'COOLTRAINER_M',  # $1F
        'CooltrainerFData'  => 'COOLTRAINER_F',  # $20
        'BrunoData'         => 'BRUNO',          # $21
        'BrockData'         => 'BROCK',          # $22
        'MistyData'         => 'MISTY',          # $23
        'LtSurgeData'       => 'LT_SURGE',       # $24
        'ErikaData'         => 'ERIKA',          # $25
        'KogaData'          => 'KOGA',           # $26
        'BlaineData'        => 'BLAINE',         # $27
        'SabrinaData'       => 'SABRINA',        # $28
        'GentlemanData'     => 'GENTLEMAN',      # $29
        'Rival2Data'        => 'RIVAL2',         # $2A
        'Rival3Data'        => 'RIVAL3',         # $2B
        'LoreleiData'       => 'LORELEI',        # $2C
        'ChannelerData'     => 'CHANNELER',      # $2D
        'AgathaData'        => 'AGATHA',         # $2E
        'LanceData'         => 'LANCE',          # $2F
    }.freeze

    def initialize(source)
        super
        @trainer_class = GROUP_TO_CLASS[source.sub(/:\z/, '')]
    end

    attr_reader :trainer_class

    def transform
        label = @trainer_class != 'YOUNGSTER' ? src : "\tdef_trainer_class NOBODY\n#{src}"
        format("%s\n\tdef_trainer_class %s", label, trainer_class)
    end
end

class AbstractParty < BaseTransformer
    def initialize(source, index)
        super(source)
        @index = index
    end

    def transform
        [starting_macro, mons_macro, terminator_macro].join("\n")
    end

    private

    def starting_macro
        "\tdef_trainer #{@index}, #{@level}"
    end

    def terminator_macro
        "\tend_trainer\n"
    end
end

class BasicParty < AbstractParty
    def initialize(source, index)
        super(source, index)
        @level, species_data = src.match(/\tdb +(\d+), +(.+), 0/).values_at(1, 2)
        @species = species_data.split(', ')
    end

    private

    def mons_macro
        @species.map { "\ttr_mon #{_1}" }.join("\n")
    end
end

class SpecialParty < AbstractParty
    def initialize(source, index)
        super(source, index)
        @level = '$FF'
        @data = src[/\tdb +\$FF, +(.+), 0/, 1].split(', ')
    end

    private

    def mons_macro
        @data.each_slice(2).map { |(level, species)| "\ttr_mon #{level}, #{species}" }.join("\n")
    end
end

options = {
    dry_run: true,
}

require 'optparse'

OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [--rewrite] <path/to/parties.asm>"

    opts.on '--rewrite' do
        options[:dry_run] = false
    end
end.parse!

filepath = ARGV.first
raise ArgumentError, "invalid file '#{filepath}'" if filepath.nil? || filepath.empty?
filepath = File.expand_path(filepath) unless File.exists?(filepath)
raise ArgumentError, "invalid file '#{filepath}'" unless File.exists?(filepath)

trainer_index = 0

data = File.readlines(filepath).map.with_index(1) do |line, linum|
    line = line.chomp
    if line.match?(/Data:\z/)
        trainer_index = 0
        TrainerGroupLabel.new(line)
    elsif line.match?(/\A\tdb /)
        party_class = line.include?('db $FF') ? SpecialParty : BasicParty
        trainer_index += 1
        begin
            party_class.new(line, trainer_index)
        rescue => e
            puts format("|%3i| %s", linum, line)
            binding.irb
        end
    else
        RawLine.new(line)
    end
end

if options[:dry_run]
    puts data.join("\n")
else
    File.open(filepath, 'w') { |f| f.puts data.join("\n") }
    puts "wrote macros into #{filepath}"
end
