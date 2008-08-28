#!/usr/bin/ruby


require 'rss/1.0'
require 'rss/2.0'
require 'open-uri'
require 'yaml'

class TracPlugin < Plugin

    def help( plugin, topic="" )
        "trac plugin: periodicly notifies channels of Trac activity.  " +
        "'trac <url>': reports on a Trac"
    end

    def initialize
      super
      @feeds = {}
      @period = 60
      @bot.timer.add( @period ) {
        self.feed
      }
    end

    def feed
      puts @feeds.to_yaml
      @feeds.each {|url,params|
        begin
          open( url ) {|page|
            data = page.read
            @bot.say params[:where], parse( data, params )
          }
        rescue OpenURI::HTTPError, EOFError
          retry         #:MC: is this going to be very bad?
        end
      }
    end

    DisplayString = "%s created '%s' at %s"
    Elements = %w[ author title pubDate ]

    def parse( data, params )
      begin
        rss = RSS::Parser.parse( data )
      rescue RSS::InvalidRSSError
        rss = RSS::Parser.parse( data, false )
      end
      message = ''
      newest = params[:last_change]
      rss.channel.items.find_all {|item|
        params[:last_change] < item.pubDate
      }.sort_by {|item| item.pubDate}.each {|item|
        newest = item.pubDate
        message += DisplayString % Elements.map {|element|
          value = item.send( element ) || ''
          value = "???" if value.kind_of?(String) and value.empty?
          value
        } + "\n"
      }
      params[:last_change] = newest
      return message
    end

    def feed_on( m, params )
      m.reply "m is '#{m.to_yaml}'"
      m.reply "params is '#{params.to_yaml}'"
      url = params[:what]
      @feeds[url] = {
        :last_change => Time.at(0),
        :where => m.channel
      }
    end

end # class TracPlugin

plugin = TracPlugin.new
plugin.map 'trac :what', :action => 'feed_on'
