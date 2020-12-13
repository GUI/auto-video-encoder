#!/usr/bin/env ruby

require "bundler/setup"

require "active_support"
require "benchmark"
require "childprocess"
require "digest"
require "fileutils"
require "highline"
require "json"
require "open3"
require "time"

require_relative "./settings.rb"

Dir.chdir(CHDIR)

MIN_SCAN_DURATION = (ENV["MIN_SCAN_DURATION"] || 5).to_i * 60
LANGUAGE = "eng"
LOG_DIR = File.join(OUTPUT_DIR, "logs")
FileUtils.mkdir_p(LOG_DIR)

STDOUT.sync = true
STDERR.sync = true

disc_paths = ARGV.sort_by { |p| p.gsub(/\d+/) { |s| "%04d" % s.to_i } }
if(disc_paths.empty?)
  puts "Must pass paths to discs as arguments"
  exit 1
end

$cli = HighLine.new
$titles = {}

def humanize_duration(duration)
  min = (duration.to_f / 60).floor
  sec = duration.to_i - min * 60
  "#{min.to_s.rjust(3)}m #{sec.to_s.rjust(2)}s"
end

def scan_disc(disc_path)
  disc_name = File.basename(disc_path)
  series = disc_name.gsub(/[-_ ](s|season)[-_ ]?\d+.*/i, "")
  series.gsub!(/[-_ ](d|disc)[-_ ]?\d+.*/i, "")
  series = ActiveSupport::Inflector.titleize(ActiveSupport::Inflector.humanize(series).strip)
  season = nil
  if(disc_name =~ /[-_ ](s|season)[-_ ]?(\d+)/i)
    season = $2
  end
  disc_num = "1"
  if(disc_name =~ /[-_ \d](d|disc)[-_ ]?(\d+)/i)
    disc_num = $2
  end

  scan_output, scan_err, status = Open3.capture3(*[
    CLI_PATH,
    "--input", disc_path,
    "--title", "0",
    "--min-duration", MIN_SCAN_DURATION.to_s,
    "--scan",
    "--json",
  ].flatten)
  if(status != 0)
    puts "Scan failed"
    puts scan_output
    puts scan_err
    exit 1
  end

  data = JSON.load(scan_output.match(/JSON Title Set: ({.*)\z/m)[1])
  data.fetch("TitleList").each do |title_list|
    title_num = title_list.fetch("Index").to_s

    duration = title_list.fetch("Duration").fetch("Hours") * 60 * 60 + title_list.fetch("Duration").fetch("Minutes") * 60 + title_list.fetch("Duration").fetch("Seconds")

    ticks = title_list.fetch("Duration").fetch("Ticks")
    chapter_ticks = title_list.fetch("ChapterList").map { |chapter| chapter.fetch("Duration").fetch("Ticks") }
    checksum = Digest::SHA256.hexdigest("#{ticks}#{chapter_ticks.join(",")}")[0, 8]

    language_subtitles = []
    title_list.fetch("SubtitleList").each_with_index do |subtitle, index|
      if subtitle.fetch("LanguageCode") == LANGUAGE
        language_subtitles << index + 1
      end
    end
    if(language_subtitles.empty?)
      title_list.fetch("SubtitleList").each_with_index do |subtitle, index|
        if subtitle.fetch("LanguageCode") == "und"
          language_subtitles << index + 1
        end
      end
    end

    season_key = { :series => series, :season => season }
    $titles[season_key] ||= []
    $titles[season_key] << {
      :disc_path => disc_path,
      :disc_name => File.basename(disc_path),
      :series => series,
      :season => season,
      :disc_num => disc_num,
      :num => title_num,
      :disc_title_num => [disc_num.rjust(2, "0"), title_num.rjust(2, "0")].join("-"),
      :ticks => ticks,
      :checksum => checksum,
      :duration => duration,
      :human_duration => "#{Time.at(duration).utc.strftime("%H:%M:%S")} #{humanize_duration(duration)}",
      :subtitles => language_subtitles.join(","),
    }
  end
end

def select_episodes(season_key, season_titles, force_add, force_remove)
  puts "\n#{season_key[:series]} S#{season_key[:season]} all titles:"
  season_titles.each do |title|
    puts "#{title[:disc_name]} Title #{title[:disc_title_num]}: #{title[:human_duration]} (#{title[:ticks]} ticks, checksum: #{title[:checksum]})"
  end
  puts "\n"

  min_duration = 0
  max_duration = 0
  $cli.choose do |menu|
    menu.prompt = "Length of show?  "
    menu.choice("Hour long (36-80 mins)") do
      min_duration = 36 * 60
      max_duration = 80 * 60
    end
    menu.choice("Half-hour long (17-40 mins)") do
      min_duration = 17 * 60
      max_duration = 40 * 60
    end
    menu.choice("Custom duration") do
      min_duration = $cli.ask("Minimum duration (mins): ", Integer) * 60
      max_duration = $cli.ask("Maximum duration (mins): ", Integer) * 60
    end
  end

  series = $cli.ask("Series Name: ") { |q| q.default = season_key[:series] }
  season = $cli.ask("Season: ", Integer) { |q| q.default = season_key[:season] || "1" }
  starting_episode = $cli.ask("Starting Episode: ", Integer) { |q| q.default = "1" }

  seen_checksums = {}
  matched_titles = season_titles.select do |title|
    match = false
    if(force_add && force_add.include?(title[:disc_title_num]))
      match = true
    elsif(force_remove && force_remove.include?(title[:disc_title_num]))
      match = false
    elsif(title[:duration] >= min_duration && title[:duration] <= max_duration)
      seen_checksum_key = [title[:disc_path], title[:checksum]].join("-")
      if(title[:subtitles].to_s.empty? && ENV["ALLOW_NO_SUBTITLES"] != "true")
        puts "WARNING: Subtitles empty, skipping: #{title.inspect}"
      elsif(seen_checksums[seen_checksum_key])
        puts "WARNING: Apparent duplicate title (same tick count), skipping: #{title.inspect}, Previously seen: #{seen_checksums[seen_checksum_key].inspect}"
      else
        seen_checksums[seen_checksum_key] = title
        match = true
      end
    end

    match
  end

  episode = starting_episode
  matched_titles.each do |title|
    title[:output_filename] = "#{series} S#{season.to_s.rjust(2, "0")}E#{episode.to_s.rjust(2, "0")} - #{title[:disc_name]}-#{title[:disc_title_num]}.mkv"
    title[:output_path] = File.join(OUTPUT_DIR, title[:output_filename])

    episode += 1
  end

  matched_titles.reject! do |title|
    if(File.exist?(title[:output_path]))
      puts "WARNING: Output file already exists, skipping: #{title[:output_path].inspect}"
      true
    else
      false
    end
  end

  puts "\nSelected titles:"
  matched_titles.each_with_index do |title, index|
    puts "#{(index + 1).to_s.rjust(2)}: #{title[:output_filename]} (#{title[:human_duration]})"
  end

  matched_titles
end

disc_paths.each do |disc_path|
  REMAP_DIRS.each do |search, replace|
    disc_path = disc_path.gsub(search, replace)
  end

  puts "Scanning #{disc_path}..."
  scan_disc(disc_path)
end

encode_titles = []
$titles.each do |season_key, season_titles|
  force_add = nil
  force_remove = nil
  loop do
    matched_titles = select_episodes(season_key, season_titles, force_add, force_remove)

    force_add = nil
    force_remove = nil
    confirm = $cli.ask("\nDo the selected episodes look correct? (y/n/e/q) ")
    case(confirm.to_s.downcase)
    when "y"
      encode_titles += matched_titles
      break
    when "e"
      force_add = $cli.ask("Enter disc-title numbers to force add (comma delimited): ").split(",")
      force_remove = $cli.ask("Enter disc-title numbers to force remove (comma delimited): ").split(",")
    when "q"
      exit 1
    end
  end
end

logger = Logger.new(File.join(LOG_DIR, "debug-#{Time.now.iso8601.gsub(":", "-")}.log"))

puts "\n"
encode_titles.each_with_index do |title, index|
  if(File.exist?(title[:output_path]))
    puts "WARNING: Output file already exists, skipping: #{title[:output_path].inspect}"
  end

  command = [
    CLI_PATH,
    "--input", title[:disc_path],
    "--title", title[:num],
    "--output", title[:output_path],
    "--format", "av_mkv",
    "--markers",
    "--no-optimize",
    "--encoder", "x264",
    "--encoder-preset", "medium",
    "--encoder-profile", "main",
    "--encoder-level", "4.0",
    "--vb", "1600",
    "--two-pass",
    "--turbo",
    "--cfr",
    "--audio-lang-list", LANGUAGE,
    "--all-audio",
    "--aencoder", "copy",
    "--audio-fallback", "av_aac",
    "--ab", "192",
    "--mixdown", "dpl2",
    "--crop", "0:0:0:0",
    "--comb-detect",
    "--decomb",
    "--detelecine",
    "--no-deblock",
    "--no-hqdn3d",
    "--no-nlmeans",
    # Enable all the English subtitles and also enable foreign-language
    # scanning. If any foreign language only tracks are found (in other words,
    # a track that just contains the foreign parts), then mark them it default,
    # so it shows up automatically.
    #
    # Do not use the --subtitle-forced option, since that doesn't lead to
    # proper behavior when a single track contains both forced and unforced
    # titles (in other words, a single track contains the foreign parts with
    # the individual frames marked forced, and also contains the normal english
    # captioning as unforced frames).
    "--subtitle", "scan,#{title[:subtitles]}",
    "--subtitle-default", "1",
    "--native-language", LANGUAGE,
  ].flatten

  progress = "\n#{(index + 1).to_s.rjust(3)}/#{encode_titles.length} - Encoding #{title[:output_filename]}..."
  puts progress
  logger.info(progress)
  logger.info(command.join(" "))
  measure = Benchmark.measure do
    process = ChildProcess.build(*command)
    process.io.inherit!
    process.io.stderr = File.open(File.join(LOG_DIR, title[:output_filename] + ".log"), "w")
    process.start
    process.wait
    if(process.exit_code != 0)
      puts "Encoding failed"
      exit 1
    end
  end
  took = "Completed in #{humanize_duration(measure.real)}"
  puts took
  logger.info(took)
end
