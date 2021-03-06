#-- vim:sw=2:et
#++
#
# :title: RSS feed plugin for rbot
#
# Author:: Stanislav Karchebny <berkus@madfire.net>
# Author:: Ian Monroe <ian@monroe.nu>
# Author:: Mark Kretschmann <markey@web.de>
# Author:: Giuseppe Bilotta <giuseppe.bilotta@gmail.com>
#
# Copyright:: (C) 2004 Stanislav Karchebny
# Copyright:: (C) 2005 Ian Monroe, Mark Kretschmann
# Copyright:: (C) 2006-2007 Giuseppe Bilotta
#
# License:: MIT license

require 'rss'

# Try to load rss/content/2.0 so we can access the data in <content:encoded> 
# tags.
begin
  require 'rss/content/2.0'
rescue LoadError
end

module ::RSS

  # Add support for Slashdot namespace in RDF. The code is just an adaptation
  # of the DublinCore code.
  unless defined?(SLASH_PREFIX)
    SLASH_PREFIX = 'slash'
    SLASH_URI = "http://purl.org/rss/1.0/modules/slash/"

    RDF.install_ns(SLASH_PREFIX, SLASH_URI)

    module BaseSlashModel
      def append_features(klass)
        super

        return if klass.instance_of?(Module)
        SlashModel::ELEMENT_NAME_INFOS.each do |name, plural_name|
          plural = plural_name || "#{name}s"
          full_name = "#{SLASH_PREFIX}_#{name}"
          full_plural_name = "#{SLASH_PREFIX}_#{plural}"
          klass_name = "Slash#{Utils.to_class_name(name)}"

          # This will fail with older version of the Ruby RSS module
          begin
            klass.install_have_children_element(name, SLASH_URI, "*",
                                                full_name, full_plural_name)
            klass.install_must_call_validator(SLASH_PREFIX, SLASH_URI)
          rescue ArgumentError
            klass.module_eval("install_have_children_element(#{full_name.dump}, #{full_plural_name.dump})")
          end

          klass.module_eval(<<-EOC, *get_file_and_line_from_caller(0))
          remove_method :#{full_name}     if method_defined? :#{full_name}
          remove_method :#{full_name}=    if method_defined? :#{full_name}=
          remove_method :set_#{full_name} if method_defined? :set_#{full_name}

          def #{full_name}
            @#{full_name}.first and @#{full_name}.first.value
          end

          def #{full_name}=(new_value)
            @#{full_name}[0] = Utils.new_with_value_if_need(#{klass_name}, new_value)
          end
          alias set_#{full_name} #{full_name}=
        EOC
        end
      end
    end

    module SlashModel
      extend BaseModel
      extend BaseSlashModel

      TEXT_ELEMENTS = {
      "department" => nil,
      "section" => nil,
      "comments" =>  nil,
      "hit_parade" => nil
      }

      ELEMENT_NAME_INFOS = SlashModel::TEXT_ELEMENTS.to_a

      ELEMENTS = TEXT_ELEMENTS.keys

      ELEMENTS.each do |name, plural_name|
        module_eval(<<-EOC, *get_file_and_line_from_caller(0))
        class Slash#{Utils.to_class_name(name)} < Element
          include RSS10

          content_setup

          class << self
            def required_prefix
              SLASH_PREFIX
            end

            def required_uri
              SLASH_URI
            end
          end

          @tag_name = #{name.dump}

          alias_method(:value, :content)
          alias_method(:value=, :content=)

          def initialize(*args)
            begin
              if Utils.element_initialize_arguments?(args)
                super
              else
                super()
                self.content = args[0]
              end
            # Older Ruby RSS module
            rescue NoMethodError
              super()
              self.content = args[0]
            end
          end

          def full_name
            tag_name_with_prefix(SLASH_PREFIX)
          end

          def maker_target(target)
            target.new_#{name}
          end

          def setup_maker_attributes(#{name})
            #{name}.content = content
          end
        end
      EOC
      end
    end

    class RDF
      class Item; include SlashModel; end
    end

    SlashModel::ELEMENTS.each do |name|
      class_name = Utils.to_class_name(name)
      BaseListener.install_class_name(SLASH_URI, name, "Slash#{class_name}")
    end

    SlashModel::ELEMENTS.collect! {|name| "#{SLASH_PREFIX}_#{name}"}
  end
end


class ::RssBlob
  attr_accessor :url, :handle, :type, :refresh_rate, :xml, :title, :items,
    :mutex, :watchers, :last_fetched

  def initialize(url,handle=nil,type=nil,watchers=[], xml=nil, lf = nil)
    @url = url
    if handle
      @handle = handle
    else
      @handle = url
    end
    @type = type
    @watchers=[]
    @refresh_rate = nil
    @xml = xml
    @title = nil
    @items = nil
    @mutex = Mutex.new
    @last_fetched = lf
    sanitize_watchers(watchers)
  end

  def dup
    @mutex.synchronize do
      self.class.new(@url,
                     @handle,
                     @type ? @type.dup : nil,
                     @watchers.dup,
                     @xml ? @xml.dup : nil,
                     @last_fetched)
    end
  end

  # Downcase all watchers, possibly turning them into Strings if they weren't
  def sanitize_watchers(list=@watchers)
    ls = list.dup
    @watchers.clear
    ls.each { |w|
      add_watch(w)
    }
  end

  def watched?
    !@watchers.empty?
  end

  def watched_by?(who)
    @watchers.include?(who.downcase)
  end

  def add_watch(who)
    if watched_by?(who)
      return nil
    end
    @mutex.synchronize do
      @watchers << who.downcase
    end
    return who
  end

  def rm_watch(who)
    @mutex.synchronize do
      @watchers.delete(who.downcase)
    end
  end

  def to_a
    [@handle,@url,@type,@refresh_rate,@watchers]
  end

  def to_s(watchers=false)
    if watchers
      a = self.to_a.flatten
    else
      a = self.to_a[0,3]
    end
    a.compact.join(" | ")
  end
end

class RSSFeedsPlugin < Plugin
  Config.register Config::IntegerValue.new('rss.head_max',
    :default => 100, :validate => Proc.new{|v| v > 0 && v < 200},
    :desc => "How many characters to use of a RSS item header")

  Config.register Config::IntegerValue.new('rss.text_max',
    :default => 200, :validate => Proc.new{|v| v > 0 && v < 400},
    :desc => "How many characters to use of a RSS item text")

  Config.register Config::IntegerValue.new('rss.thread_sleep',
    :default => 300, :validate => Proc.new{|v| v > 30},
    :desc => "How many seconds to sleep before checking RSS feeds again")

  Config.register Config::BooleanValue.new('rss.show_updated',
    :default => true,
    :desc => "Whether feed items for which the description was changed should be shown as new")

  Config.register Config::BooleanValue.new('rss.show_links',
    :default => true,
    :desc => "Whether to display links from the text of a feed item.")

  # Make an  'unique' ID for a given item, based on appropriate bot options
  # Currently only suppored is bot.config['rss.show_updated']: when false,
  # only the guid/link is accounted for.
  
  def block_rescue(df = nil, &block)
    v = block.call rescue nil
    (String === v && '' != v) ? v : nil
  end

  def make_uid(item)
    uid = [
      (block_rescue do item.guid.content end ||
       block_rescue do item.guid end ||
       block_rescue do item.link.href end ||
       block_rescue do item.link end
      )
    ]
    if @bot.config['rss.show_updated']
      uid.push(
        block_rescue do item.content.content end ||
        block_rescue do item.description end
      )
      uid.unshift(
        block_rescue do item.title.content end ||
        block_rescue do item.title end
      )
    end
    # debug "taking hash of #{uid.inspect}"
    uid.hash
  end


  # We used to save the Mutex with the RssBlob, which was idiotic. And
  # since Mutexes dumped in one version might not be resotrable in another,
  # we need a few tricks to be able to restore data from other versions of Ruby
  #
  # When migrating 1.8.6 => 1.8.5, all we need to do is define an empty
  # #marshal_load() method for Mutex. For 1.8.5 => 1.8.6 we need something
  # dirtier, as seen later on in the initialization code.
  unless Mutex.new.respond_to?(:marshal_load)
    class ::Mutex
      def marshal_load(str)
        return
      end
    end
  end

  # Auxiliary method used to collect two lines for rss output filters,
  # running substitutions against DataStream _s_ optionally joined
  # with hash _h_
  def make_stream(line1, line2, s, h={})
    ss = s.merge(h)
    DataStream.new([line1, line2].compact.join("\n") % ss, ss)
  end

  # Define default RSS filters
  #
  # TODO: load personal ones
  def define_filters
    @outkey = :"rss.out"
    @bot.register_filter(:blog, @outkey) { |s|
      author = s[:author] ? (s[:author] + " ") : ""
      abt = s[:category] ? "about #{s[:category]} " : ""
      line1 = "%{handle}%{date}%{author}blogged %{abt}at %{link}"
      line2 = "%{handle}%{title} - %{desc}"
      make_stream(line1, line2, s, :author => author, :abt => abt)
    }
    @bot.register_filter(:photoblog, @outkey) { |s|
      author = s[:author] ? (s[:author] + " ") : ""
      abt = s[:category] ? "under #{s[:category]} " : ""
      line1 = "%{handle}%{date}%{author}added an image %{abt}at %{link}"
      line2 = "%{handle}%{title} - %{desc}"
      make_stream(line1, line2, s, :author => author, :abt => abt)
    }
    @bot.register_filter(:news, @outkey) { |s|
      line1 = "%{handle}%{date}%{title} @ %{link}" % s
      line2 = "%{handle}%{date}%{desc}" % s
      make_stream(line1, line2, s)
    }
    @bot.register_filter(:git, @outkey) { |s|
      author = s[:author] ? (s[:author] + " ") : ""
      line1 = "%{handle}%{date}%{author}committed %{title} @ %{link}"
      make_stream(line1, nil, s, :author => author)
    }
    @bot.register_filter(:forum, @outkey) { |s|
      line1 = "%{handle}%{date}%{title}%{at}%{link}"
      make_stream(line1, nil, s)
    }
    @bot.register_filter(:wiki, @outkey) { |s|
      line1 = "%{handle}%{date}%{title}%{at}%{link}"
      line1 << "has been edited by %{author}. %{desc}"
      make_stream(line1, nil, s)
    }
    @bot.register_filter(:gmane, @outkey) { |s|
      line1 = "%{handle}%{date}Message %{title} sent by %{author}. %{desc}"
      make_stream(line1, nil, s)
    }
    @bot.register_filter(:trac, @outkey) { |s|
      author = s[:author].sub(/@\S+?\s*>/, "@...>") + ": " if s[:author]
      line1 = "%{handle}%{date}%{author}%{title} @ %{link}"
      line2 = nil
      unless s[:item].title =~ /^(?:Changeset \[(?:[\da-f]+)\]|\(git commit\))/
        line2 = "%{handle}%{date}%{desc}"
      end
      make_stream(line1, line2, s, :author => author)
    }
    @bot.register_filter(:"/.", @outkey) { |s|
      dept = "(from the #{s[:item].slash_department} dept) " rescue nil
      sec = " in section #{s[:item].slash_section}" rescue nil
      line1 = "%{handle}%{date}%{dept}%{title}%{at}%{link} "
      line1 << "(posted by %{author}%{sec})"
      make_stream(line1, nil, s, :dept => dept, :sec => sec)
    }
    @bot.register_filter(:default, @outkey) { |s|
      line1 = "%{handle}%{date}%{title}%{at}%{link}"
      line1 << " (by %{author})" if s[:author]
      make_stream(line1, nil, s)
    }

    # Define an HTML info filter too
    @bot.register_filter(:rss, :htmlinfo) { |s| htmlinfo_filter(s) }

    # This is the output format used by the input filter
    @bot.register_filter(:htmlinfo, @outkey) { |s|
      line1 = "%{title}%{at}%{link}"
      make_stream(line1, nil, s)
    }
  end

  FEED_NS = %r{xmlns.*http://(purl\.org/rss|www.w3c.org/1999/02/22-rdf)}
  def htmlinfo_filter(s)
    return nil unless s[:headers] and s[:headers]['x-rbot-location']
    return nil unless s[:headers]['content-type'].first.match(/xml|rss|atom|rdf/i) or
      (s[:text].include?("<rdf:RDF") and s[:text].include?("<channel")) or
      s[:text].include?("<rss") or s[:text].include?("<feed") or
      s[:text].match(FEED_NS)
    blob = RssBlob.new(s[:headers]['x-rbot-location'],"", :htmlinfo)
    unless (fetchRss(blob, nil) and parseRss(blob, nil) rescue nil)
      debug "#{s.pretty_inspect} is not an RSS feed, despite the appearances"
      return nil
    end
    output = []
    blob.items.each { |it|
      output << printFormattedRss(blob, it)[:text]
    }
    return {:title => blob.title, :content => output.join(" | ")}
  end

  # Display the known rss types
  def rss_types(m, params)
    ar = @bot.filter_names(@outkey)
    ar.delete(:default)
    m.reply ar.map { |k| k.to_s }.sort!.join(", ")
  end

  attr_reader :feeds

  def initialize
    super

    define_filters

    if @registry.has_key?(:feeds)
      # When migrating from Ruby 1.8.5 to 1.8.6, dumped Mutexes may render the
      # data unrestorable. If this happens, we patch the data, thus allowing
      # the restore to work.
      #
      # This is actually pretty safe for a number of reasons:
      # * the code is only called if standard marshalling fails
      # * the string we look for is quite unlikely to appear randomly
      # * if the string appears somewhere and the patched string isn't recoverable
      #   either, we'll get another (unrecoverable) error, which makes the rss
      #   plugin unsable, just like it was if no recovery was attempted
      # * if the string appears somewhere and the patched string is recoverable,
      #   we may get a b0rked feed, which is eventually overwritten by a clean
      #   one, so the worst thing that can happen is that a feed update spams
      #   the watchers once
      @registry.recovery = Proc.new { |val|
        patched = val.sub(":\v@mutexo:\nMutex", ":\v@mutexo:\vObject")
        ret = Marshal.restore(patched)
        ret.each_value { |blob|
          blob.mutex = nil
          blob
        }
      }

      @feeds = @registry[:feeds]
      raise unless @feeds

      @registry.recovery = nil

      @feeds.keys.grep(/[A-Z]/) { |k|
        @feeds[k.downcase] = @feeds[k]
        @feeds.delete(k)
      }
      @feeds.each { |k, f|
        f.mutex = Mutex.new
        f.sanitize_watchers
        parseRss(f) if f.xml
      }
    else
      @feeds = Hash.new
    end
    @watch = Hash.new
    rewatch_rss
  end

  def name
    "rss"
  end

  def watchlist
    @feeds.select { |h, f| f.watched? }
  end

  def cleanup
    stop_watches
    super
  end

  def save
    unparsed = Hash.new()
    @feeds.each { |k, f|
      unparsed[k] = f.dup
      # we don't want to save the mutex
      unparsed[k].mutex = nil
    }
    @registry[:feeds] = unparsed
  end

  def stop_watch(handle)
    if @watch.has_key?(handle)
      begin
        debug "Stopping watch #{handle}"
        @bot.timer.remove(@watch[handle])
        @watch.delete(handle)
      rescue Exception => e
        report_problem("Failed to stop watch for #{handle}", e, nil)
      end
    end
  end

  def stop_watches
    @watch.each_key { |k|
      stop_watch(k)
    }
  end

  def help(plugin,topic="")
    case topic
    when "show"
      "rss show #{Bold}handle#{Bold} [#{Bold}limit#{Bold}] : show #{Bold}limit#{Bold} (default: 5, max: 15) entries from rss #{Bold}handle#{Bold}; #{Bold}limit#{Bold} can also be in the form a..b, to display a specific range of items"
    when "list"
      "rss list [#{Bold}handle#{Bold}] : list all rss feeds (matching #{Bold}handle#{Bold})"
    when "watched"
      "rss watched [#{Bold}handle#{Bold}] [in #{Bold}chan#{Bold}]: list all watched rss feeds (matching #{Bold}handle#{Bold}) (in channel #{Bold}chan#{Bold})"
    when "who", "watches", "who watches"
      "rss who watches [#{Bold}handle#{Bold}]]: list all watchers for rss feeds (matching #{Bold}handle#{Bold})"
    when "add"
      "rss add #{Bold}handle#{Bold} #{Bold}url#{Bold} [#{Bold}type#{Bold}] : add a new rss called #{Bold}handle#{Bold} from url #{Bold}url#{Bold} (of type #{Bold}type#{Bold})"
    when "change"
      "rss change #{Bold}what#{Bold} of #{Bold}handle#{Bold} to #{Bold}new#{Bold} : change the #{Underline}handle#{Underline}, #{Underline}url#{Underline}, #{Underline}type#{Underline} or #{Underline}refresh#{Underline} rate of rss called #{Bold}handle#{Bold} to value #{Bold}new#{Bold}"
    when /^(del(ete)?|rm)$/
      "rss del(ete)|rm #{Bold}handle#{Bold} : delete rss feed #{Bold}handle#{Bold}"
    when "replace"
      "rss replace #{Bold}handle#{Bold} #{Bold}url#{Bold} [#{Bold}type#{Bold}] : try to replace the url of rss called #{Bold}handle#{Bold} with #{Bold}url#{Bold} (of type #{Bold}type#{Bold}); only works if nobody else is watching it"
    when "forcereplace"
      "rss forcereplace #{Bold}handle#{Bold} #{Bold}url#{Bold} [#{Bold}type#{Bold}] : replace the url of rss called #{Bold}handle#{Bold} with #{Bold}url#{Bold} (of type #{Bold}type#{Bold})"
    when "watch"
      "rss watch #{Bold}handle#{Bold} [#{Bold}url#{Bold} [#{Bold}type#{Bold}]]  [in #{Bold}chan#{Bold}]: watch rss #{Bold}handle#{Bold} for changes (in channel #{Bold}chan#{Bold}); when the other parameters are present, the feed will be created if it doesn't exist yet"
    when /(un|rm)watch/
      "rss unwatch|rmwatch #{Bold}handle#{Bold} [in #{Bold}chan#{Bold}]: stop watching rss #{Bold}handle#{Bold} (in channel #{Bold}chan#{Bold}) for changes"
    when  /who(?: watche?s?)?/
      "rss who watches #{Bold}handle#{Bold}: lists watches for rss #{Bold}handle#{Bold}"
    when "rewatch"
      "rss rewatch : restart threads that watch for changes in watched rss"
    when "types"
      "rss types : show the rss types for which an output format existi (all other types will use the default one)"
    else
      "manage RSS feeds: rss types|show|list|watched|add|change|del(ete)|rm|(force)replace|watch|unwatch|rmwatch|rewatch|who watches"
    end
  end

  def report_problem(report, e=nil, m=nil)
    if m && m.respond_to?(:reply)
      m.reply report
    else
      warning report
    end
    if e
      debug e.inspect
      debug e.backtrace.join("\n") if e.respond_to?(:backtrace)
    end
  end

  def show_rss(m, params)
    handle = params[:handle]
    lims = params[:limit].to_s.match(/(\d+)(?:..(\d+))?/)
    debug lims.to_a.inspect
    if lims[2]
      ll = [[lims[1].to_i-1,lims[2].to_i-1].min,  0].max
      ul = [[lims[1].to_i-1,lims[2].to_i-1].max, 14].min
      rev = lims[1].to_i > lims[2].to_i
    else
      ll = 0
      ul = [[lims[1].to_i-1, 0].max, 14].min
      rev = false
    end

    feed = @feeds.fetch(handle.downcase, nil)
    unless feed
      m.reply "I don't know any feeds named #{handle}"
      return
    end

    m.reply "lemme fetch it..."
    title = items = nil
    we_were_watching = false

    if @watch.key?(feed.handle)
      # If a feed is being watched, we run the watcher thread
      # so that all watchers can be informed of changes to
      # the feed. Before we do that, though, we remove the
      # show requester from the watchlist, if present, lest
      # he gets the update twice.
      if feed.watched_by?(m.replyto)
        we_were_watching = true
        feed.rm_watch(m.replyto)
      end
      @bot.timer.reschedule(@watch[feed.handle], 0)
      if we_were_watching
        feed.add_watch(m.replyto)
      end
    else
      fetched = fetchRss(feed, m, false)
    end
    return unless fetched or feed.xml
    if fetched or not feed.items
      parsed = parseRss(feed, m)
    end
    return unless feed.items
    m.reply "using old data" unless fetched and parsed

    title = feed.title
    items = feed.items

    # We sort the feeds in freshness order (newer ones first)
    items = freshness_sort(items)
    disp = items[ll..ul]
    disp.reverse! if rev

    m.reply "Channel : #{title}"
    disp.each do |item|
      printFormattedRss(feed, item, {:places=>[m.replyto],:handle=>nil,:date=>true})
    end
  end

  def itemDate(item,ex=nil)
    return item.pubDate if item.respond_to?(:pubDate) and item.pubDate
    return item.date if item.respond_to?(:date) and item.date
    return ex
  end

  def freshness_sort(items)
    notime = Time.at(0)
    items.sort { |a, b|
      itemDate(b, notime) <=> itemDate(a, notime)
    }
  end

  def list_rss(m, params)
    wanted = params[:handle]
    reply = String.new
    @feeds.each { |handle, feed|
      next if wanted and !handle.match(/#{wanted}/i)
      reply << "#{feed.handle}: #{feed.url} (in format: #{feed.type ? feed.type : 'default'})"
      (reply << " refreshing every #{Utils.secs_to_string(feed.refresh_rate)}") if feed.refresh_rate
      (reply << " (watched)") if feed.watched_by?(m.replyto)
      reply << "\n"
    }
    if reply.empty?
      reply = "no feeds found"
      reply << " matching #{wanted}" if wanted
    end
    m.reply reply, :max_lines => reply.length
  end

  def watched_rss(m, params)
    wanted = params[:handle]
    chan = params[:chan] || m.replyto
    reply = String.new
    watchlist.each { |handle, feed|
      next if wanted and !handle.match(/#{wanted}/i)
      next unless feed.watched_by?(chan)
      reply << "#{feed.handle}: #{feed.url} (in format: #{feed.type ? feed.type : 'default'})"
      (reply << " refreshing every #{Utils.secs_to_string(feed.refresh_rate)}") if feed.refresh_rate
      reply << "\n"
    }
    if reply.empty?
      reply = "no watched feeds"
      reply << " matching #{wanted}" if wanted
    end
    m.reply reply
  end

  def who_watches(m, params)
    wanted = params[:handle]
    reply = String.new
    watchlist.each { |handle, feed|
      next if wanted and !handle.match(/#{wanted}/i)
      reply << "#{feed.handle}: #{feed.url} (in format: #{feed.type ? feed.type : 'default'})"
      (reply << " refreshing every #{Utils.secs_to_string(feed.refresh_rate)}") if feed.refresh_rate
      reply << ": watched by #{feed.watchers.join(', ')}"
      reply << "\n"
    }
    if reply.empty?
      reply = "no watched feeds"
      reply << " matching #{wanted}" if wanted
    end
    m.reply reply
  end

  def add_rss(m, params, force=false)
    handle = params[:handle]
    url = params[:url]
    unless url.match(/https?/)
      m.reply "I only deal with feeds from HTTP sources, so I can't use #{url} (maybe you forgot the handle?)"
      return
    end
    type = params[:type]
    if @feeds.fetch(handle.downcase, nil) && !force
      m.reply "There is already a feed named #{handle} (URL: #{@feeds[handle.downcase].url})"
      return
    end
    unless url
      m.reply "You must specify both a handle and an url to add an RSS feed"
      return
    end
    @feeds[handle.downcase] = RssBlob.new(url,handle,type)
    reply = "Added RSS #{url} named #{handle}"
    if type
      reply << " (format: #{type})"
    end
    m.reply reply
    return handle
  end

  def change_rss(m, params)
    handle = params[:handle].downcase
    feed = @feeds.fetch(handle, nil)
    unless feed
      m.reply "No such feed with handle #{handle}"
      return
    end
    case params[:what].intern
    when :handle
      new = params[:new].downcase
      if @feeds.key?(new) and @feeds[new]
        m.reply "There already is a feed with handle #{new}"
        return
      else
        feed.mutex.synchronize do
          @feeds[new] = feed
          @feeds.delete(handle)
          feed.handle = new
        end
        handle = new
      end
    when :url
      new = params[:new]
      feed.mutex.synchronize do
        feed.url = new
      end
    when :format, :type
      new = params[:new]
      new = nil if new == 'default'
      feed.mutex.synchronize do
        feed.type = new
      end
    when :refresh
      new = params[:new].to_i
      new = nil if new == 0
      feed.mutex.synchronize do
        feed.refresh_rate = new
      end
    else
      m.reply "Don't know how to change #{params[:what]} for feeds"
      return
    end
    m.reply "Feed changed:"
    list_rss(m, {:handle => handle})
  end

  def del_rss(m, params, pass=false)
    feed = unwatch_rss(m, params, true)
    return unless feed
    if feed.watched?
      m.reply "someone else is watching #{feed.handle}, I won't remove it from my list"
      return
    end
    @feeds.delete(feed.handle.downcase)
    m.okay unless pass
    return
  end

  def replace_rss(m, params)
    handle = params[:handle]
    if @feeds.key?(handle.downcase)
      del_rss(m, {:handle => handle}, true)
    end
    if @feeds.key?(handle.downcase)
      m.reply "can't replace #{feed.handle}"
    else
      add_rss(m, params, true)
    end
  end

  def forcereplace_rss(m, params)
    add_rss(m, params, true)
  end

  def watch_rss(m, params)
    handle = params[:handle]
    chan = params[:chan] || m.replyto
    url = params[:url]
    type = params[:type]
    if url
      add_rss(m, params)
    end
    feed = @feeds.fetch(handle.downcase, nil)
    if feed
      if feed.add_watch(chan)
        watchRss(feed, m)
        m.okay
      else
        m.reply "Already watching #{feed.handle} in #{chan}"
      end
    else
      m.reply "Couldn't watch feed #{handle} (no such feed found)"
    end
  end

  def unwatch_rss(m, params, pass=false)
    handle = params[:handle].downcase
    chan = params[:chan] || m.replyto
    unless @feeds.has_key?(handle)
      m.reply("dunno that feed")
      return
    end
    feed = @feeds[handle]
    if feed.rm_watch(chan)
      m.reply "#{chan} has been removed from the watchlist for #{feed.handle}"
    else
      m.reply("#{chan} wasn't watching #{feed.handle}") unless pass
    end
    if !feed.watched?
      stop_watch(handle)
    end
    return feed
  end

  def rewatch_rss(m=nil, params=nil)
    if params and handle = params[:handle]
      feed = @feeds.fetch(handle.downcase, nil)
      if feed
        @bot.timer.reschedule(@watch[feed.handle], (params[:delay] || 0).to_f)
        m.okay if m
      else
        m.reply _("no such feed %{handle}") % { :handle => handle } if m
      end
    else
      stop_watches

      # Read watches from list.
      watchlist.each{ |handle, feed|
        watchRss(feed, m)
      }
      m.okay if m
    end
  end

  private
  def watchRss(feed, m=nil)
    if @watch.has_key?(feed.handle)
      report_problem("watcher thread for #{feed.handle} is already running", nil, m)
      return
    end
    status = Hash.new
    status[:failures] = 0
    tmout = 0
    if feed.last_fetched
      tmout = feed.last_fetched + calculate_timeout(feed) - Time.now
      tmout = 0 if tmout < 0
    end
    debug "scheduling a watcher for #{feed} in #{tmout} seconds"
    @watch[feed.handle] = @bot.timer.add(tmout) {
      debug "watcher for #{feed} wakes up"
      failures = status[:failures]
      begin
        debug "fetching #{feed}"
        first_run = !feed.last_fetched
        oldxml = feed.xml ? feed.xml.dup : nil
        unless fetchRss(feed)
          failures += 1
        else
          if first_run
            debug "first run for #{feed}, getting items"
            parseRss(feed)
          elsif oldxml and oldxml == feed.xml
            debug "xml for #{feed} didn't change"
            failures -= 1 if failures > 0
          else
            if not feed.items
              debug "no previous items in feed #{feed}"
              parseRss(feed)
              failures -= 1 if failures > 0
            else
              # This one is used for debugging
              otxt = []

              # These are used for checking new items vs old ones
              oids = Set.new feed.items.map { |item|
                uid = make_uid item
                otxt << item.to_s
                debug [uid, item].inspect
                debug [uid, otxt.last].inspect
                uid
              }

              unless parseRss(feed)
                debug "no items in feed #{feed}"
                failures += 1
              else
                debug "Checking if new items are available for #{feed}"
                failures -= 1 if failures > 0
                # debug "Old:"
                # debug oldxml
                # debug "New:"
                # debug feed.xml

                dispItems = feed.items.reject { |item|
                  uid = make_uid item
                  txt = item.to_s
                  if oids.include?(uid)
                    debug "rejecting old #{uid} #{item.inspect}"
                    debug [uid, txt].inspect
                    true
                  else
                    debug "accepting new #{uid} #{item.inspect}"
                    debug [uid, txt].inspect
                    warning "same text! #{txt}" if otxt.include?(txt)
                    false
                  end
                }

                if dispItems.length > 0
                  debug "Found #{dispItems.length} new items in #{feed}"
                  # When displaying watched feeds, publish them from older to newer
                  dispItems.reverse.each { |item|
                    printFormattedRss(feed, item)
                  }
                else
                  debug "No new items found in #{feed}"
                end
              end
            end
          end
        end
      rescue Exception => e
        error "Error watching #{feed}: #{e.inspect}"
        debug e.backtrace.join("\n")
        failures += 1
      end

      status[:failures] = failures

      seconds = calculate_timeout(feed, failures)
      debug "watcher for #{feed} going to sleep #{seconds} seconds.."
      begin
        @bot.timer.reschedule(@watch[feed.handle], seconds)
      rescue
        warning "watcher for #{feed} failed to reschedule: #{$!.inspect}"
      end
    }
    debug "watcher for #{feed} added"
  end

  def calculate_timeout(feed, failures = 0)
      seconds = @bot.config['rss.thread_sleep']
      feed.mutex.synchronize do
        seconds = feed.refresh_rate if feed.refresh_rate
      end
      seconds *= failures + 1
      seconds += seconds * (rand(100)-50)/100
      return seconds
  end

  def select_nonempty(*ar)
    # debug ar
    ar.each { |i| return i unless i.nil_or_empty? }
    return nil
  end

  def printFormattedRss(feed, item, opts=nil)
    # debug item
    places = feed.watchers
    handle = feed.handle.empty? ? "" : "::#{feed.handle}:: "
    date = String.new
    if opts
      places = opts[:places] if opts.key?(:places)
      handle = opts[:handle].to_s if opts.key?(:handle)
      if opts.key?(:date) && opts[:date]
        if item.respond_to?(:updated)
          if item.updated.content.class <= Time
            date = item.updated.content.strftime("%Y/%m/%d %H:%M")
          else
            date = item.updated.content.to_s
          end
        elsif item.respond_to?(:source) and item.source.respond_to?(:updated)
          if item.source.updated.content.class <= Time
            date = item.source.updated.content.strftime("%Y/%m/%d %H:%M")
          else
            date = item.source.updated.content.to_s
          end
        elsif item.respond_to?(:pubDate) 
          if item.pubDate.class <= Time
            date = item.pubDate.strftime("%Y/%m/%d %H:%M")
          else
            date = item.pubDate.to_s
          end
        elsif item.respond_to?(:date)
          if item.date.class <= Time
            date = item.date.strftime("%Y/%m/%d %H:%M")
          else
            date = item.date.to_s
          end
        else
          date = "(no date)"
        end
        date += " :: "
      end
    end

    tit_opt = {}
    # Twitters don't need a cap on the title length since they have a hard
    # limit to 160 characters, and most of them are under 140 characters
    tit_opt[:limit] = @bot.config['rss.head_max'] unless feed.type == 'twitter'

    if item.title
      base_title = item.title.to_s.dup
      # git changesets are SHA1 hashes (40 hex digits), way too long, get rid of them, as they are
      # visible in the URL anyway
      # TODO make this optional?
      base_title.sub!(/^Changeset \[([\da-f]{40})\]:/) { |c| "(git commit)"} if feed.type == 'trac'
      title = "#{Bold}#{base_title.ircify_html(tit_opt)}#{Bold}"
    end

    desc_opt = {}
    desc_opt[:limit] = @bot.config['rss.text_max']
    desc_opt[:a_href] = :link_out if @bot.config['rss.show_links']

    # We prefer content_encoded here as it tends to provide more html formatting 
    # for use with ircify_html.
    if item.respond_to?(:content_encoded) && item.content_encoded
      desc = item.content_encoded.ircify_html(desc_opt)
    elsif item.respond_to?(:description) && item.description
      desc = item.description.ircify_html(desc_opt)
    elsif item.respond_to?(:content) && item.content
      if item.content.type == "html"
        desc = item.content.content.ircify_html(desc_opt)
      else
        desc = item.content.content
        if desc.size > desc_opt[:limit]
          desc = desc.slice(0, desc_opt[:limit]) + "#{Reverse}...#{Reverse}"
        end
      end
    else
      desc = "(?)"
    end

    link = item.link.href rescue item.link rescue nil
    link.strip! if link

    category = select_nonempty((item.category.content rescue nil), (item.dc_subject rescue nil))
    category.strip! if category
    author = select_nonempty((item.author.name.content rescue nil), (item.dc_creator rescue nil), (item.author rescue nil))
    author.strip! if author

    line1 = nil
    line2 = nil

    at = ((item.title && item.link) ? ' @ ' : '')

    key = @bot.global_filter_name(feed.type, @outkey)
    key = @bot.global_filter_name(:default, @outkey) unless @bot.has_filter?(key)

    output = @bot.filter(key, :item => item, :handle => handle, :date => date,
                         :title => title, :desc => desc, :link => link,
                         :category => category, :author => author, :at => at)

    return output if places.empty?

    places.each { |loc|
      output.to_s.each_line { |line|
        @bot.say loc, line, :overlong => :truncate
      }
    }
  end

  def fetchRss(feed, m=nil, cache=true)
    feed.last_fetched = Time.now
    begin
      # Use 60 sec timeout, cause the default is too low
      xml = @bot.httputil.get(feed.url,
                              :read_timeout => 60,
                              :open_timeout => 60,
                              :cache => cache)
    rescue URI::InvalidURIError, URI::BadURIError => e
      report_problem("invalid rss feed #{feed.url}", e, m)
      return nil
    rescue => e
      report_problem("error getting #{feed.url}", e, m)
      return nil
    end
    debug "fetched #{feed}"
    unless xml
      report_problem("reading feed #{feed} failed", nil, m)
      return nil
    end
    # Ok, 0.9 feeds are not supported, maybe because
    # Netscape happily removed the DTD. So what we do is just to
    # reassign the 0.9 RDFs to 1.0, and hope it goes right.
    xml.gsub!("xmlns=\"http://my.netscape.com/rdf/simple/0.9/\"",
              "xmlns=\"http://purl.org/rss/1.0/\"")
    feed.mutex.synchronize do
      feed.xml = xml
    end
    return true
  end

  def parseRss(feed, m=nil)
    return nil unless feed.xml
    feed.mutex.synchronize do
      xml = feed.xml
      begin
        ## do validate parse
        rss = RSS::Parser.parse(xml)
        debug "parsed and validated #{feed}"
      rescue RSS::InvalidRSSError
        ## do non validate parse for invalid RSS 1.0
        begin
          rss = RSS::Parser.parse(xml, false)
          debug "parsed but not validated #{feed}"
        rescue RSS::Error => e
          report_problem("parsing rss stream failed, whoops =(", e, m)
          return nil
        end
      rescue RSS::Error => e
        report_problem("parsing rss stream failed, oioi", e, m)
        return nil
      rescue => e
        report_problem("processing error occured, sorry =(", e, m)
        return nil
      end
      items = []
      if rss.nil?
        if xml.match(/xmlns\s*=\s*(['"])http:\/\/www.w3.org\/2005\/Atom\1/) and not defined?(RSS::Atom)
          report_problem("#{feed.handle} @ #{feed.url} looks like an Atom feed, but your Ruby/RSS library doesn't seem to support it. Consider getting the latest version from http://raa.ruby-lang.org/project/rss/", nil, m)
        else
          report_problem("#{feed.handle} @ #{feed.url} doesn't seem to contain an RSS or Atom feed I can read", nil, m)
        end
        return nil
      else
        begin
          rss.output_encoding = 'UTF-8'
        rescue RSS::UnknownConvertMethod => e
          report_problem("bah! something went wrong =(", e, m)
          return nil
        end
        if rss.respond_to? :channel
          rss.channel.title ||= "(?)"
          title = rss.channel.title
        else
          title = rss.title.content
        end
        rss.items.each do |item|
          item.title ||= "(?)"
          items << item
        end
      end

      if items.empty?
        report_problem("no items found in the feed, maybe try weed?", e, m)
        return nil
      end
      feed.title = title
      feed.items = items
      return true
    end
  end
end

plugin = RSSFeedsPlugin.new

plugin.default_auth( 'edit', false )
plugin.default_auth( 'edit:add', true)

plugin.map 'rss show :handle :limit',
  :action => 'show_rss',
  :requirements => {:limit => /^\d+(?:\.\.\d+)?$/},
  :defaults => {:limit => 5}
plugin.map 'rss list :handle',
  :action => 'list_rss',
  :defaults => {:handle => nil}
plugin.map 'rss watched :handle [in :chan]',
  :action => 'watched_rss',
  :defaults => {:handle => nil}
plugin.map 'rss who watches :handle',
  :action => 'who_watches',
  :defaults => {:handle => nil}
plugin.map 'rss add :handle :url :type',
  :action => 'add_rss',
  :auth_path => 'edit',
  :defaults => {:type => nil}
plugin.map 'rss change :what of :handle to :new',
  :action => 'change_rss',
  :auth_path => 'edit',
  :requirements => { :what => /handle|url|format|type|refresh/ }
plugin.map 'rss change :what for :handle to :new',
  :action => 'change_rss',
  :auth_path => 'edit',
  :requirements => { :what => /handle|url|format|type|refesh/ }
plugin.map 'rss del :handle',
  :auth_path => 'edit:rm!',
  :action => 'del_rss'
plugin.map 'rss delete :handle',
  :auth_path => 'edit:rm!',
  :action => 'del_rss'
plugin.map 'rss rm :handle',
  :auth_path => 'edit:rm!',
  :action => 'del_rss'
plugin.map 'rss replace :handle :url :type',
  :auth_path => 'edit',
  :action => 'replace_rss',
  :defaults => {:type => nil}
plugin.map 'rss forcereplace :handle :url :type',
  :auth_path => 'edit',
  :action => 'forcereplace_rss',
  :defaults => {:type => nil}
plugin.map 'rss watch :handle [in :chan]',
  :action => 'watch_rss',
  :defaults => {:url => nil, :type => nil}
plugin.map 'rss watch :handle :url :type [in :chan]',
  :action => 'watch_rss',
  :defaults => {:url => nil, :type => nil}
plugin.map 'rss unwatch :handle [in :chan]',
  :action => 'unwatch_rss'
plugin.map 'rss rmwatch :handle [in :chan]',
  :action => 'unwatch_rss'
plugin.map 'rss rewatch [:handle] [:delay]',
  :action => 'rewatch_rss'
plugin.map 'rss types',
  :action => 'rss_types'
