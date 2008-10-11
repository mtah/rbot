#
# :title: Email notification plugin for rbot <http://ruby-rbot.org>
# :version: 0.01 (rudimentary and experimental)
#
# Author:: Martin Häger <martin.haeger@gmail.com>
# Copyright:: (C) 2008 Martin Häger
# License:: GPLv2
#
# This plugin does not yet support POP3 over SSL, since that is a feature of Ruby 1.9. 
# In the meantime, you can use a tool like stunnel <http://www.stunnel.org>.
#
# Visit http://mtah.lighthouseapp.com/projects/15943-rbot to view open tickets for this plugin
#

require 'net/pop'
require 'iconv'

# Regular expression for matching RFC2047 encoded strings
WORD = %r{=\?([!#$\%&'*+-/0-9A-Z\\^\`a-z{|}~]+)\?([BbQq])\?([!->@-~]+)\?=}

# Default port used for POP3 connections (if not specified)
DEFAULT_PORT_POP3 = 110

class EmailPlugin < Plugin
	
	Config.register Config::IntegerValue.new('email.announcement_interval', 
	:default => 300, :validate => Proc.new { |v| v > 0 },
	:on_change => Proc.new { |bot, interval| 
		bot.timer.reschedule(EmailPlugin.announcer, interval) unless EmailPlugin.announcer.nil?
	},
	:desc => "The time between two announcement rounds (in seconds).")
	
	Config.register Config::IntegerValue.new('email.announcement_limit',
    :default => 5, :validate => Proc.new { |v| v > 0 },
    :desc => "Maximum number of mails announced by the plugin at one point.")
    
  def self.announcer
  	@@announcer
  end
  
  def initialize
    super
    
    # keeps track of the unique ids of all fetched mails to avoid re-fetching mails
    @fetched_mails = @registry.has_key?(:fetched_mails) ? @registry[:fetched_mails] : []

    # all registered accounts
    @accounts = @registry.has_key?(:accounts) ? @registry[:accounts] : {}
	
    # all announced accounts
    @announcements = @registry.has_key?(:announcements) ? @registry[:announcements] : {}
    
    # is current ly announcing?
    @is_announcing = false
    
    # add announcement action to timer
    @@announcer = @bot.timer.add(@bot.config['email.announcement_interval']) {
    	unless @is_announcing	# do not start another announcement if bot already is announcing
          
    		@is_announcing = true
    		
 
    		@announcements.each do |account_name, targets|
    			begin 
    				
            fetch_mail(account_name, @bot.config['email.announcement_limit']) do |subject,from|
                targets.each {|target| @bot.say(target, "#{Bold}MAIL:#{Bold} '#{subject}' from #{from}")}
            end
                
          rescue AnnouncementLimitReached => report 
          	targets.each {|target| @bot.say(target, "There are #{Bold}#{report.unfetched_mails}#{Bold} new message(s) left in #{account_name} (announcement limit reached). Use #{Bold}email check #{account_name}#{Bold} to view them.")}
          end	
        end
      
        @is_announcing = false
      
      end      
    }
  end
  
  def help(plugin, topic="")
  	case topic
  	when "add"
  		"#{Bold}email add <account name> <username> <password> <server> [<port>]#{Bold} => adds a new account. If <port> is not specified, the default port will be used (POP3: #{DEFAULT_PORT_POP3})."
  	when "delete"
  		"#{Bold}email delete <account name>#{Bold} => deletes an account."
  	when "list"
  		"#{Bold}email list#{Bold} => lists all accounts."
  	when "show"
  		"#{Bold}email show <account name>#{Bold} => shows information about an account."
  	when "set"
  		"#{Bold}email set <account name> <parameter> <value>#{Bold} => modifies account information. Valid  values of <parameter> are: username, password, server, port. #{Bold}Example:#{Bold} email set myaccount server pop.gmail.com"
  	when "announce"
  		"#{Bold}email announce <account name> <target> [<target2> <target3> ...]#{Bold} => start announcing an email account. <target> can either be a channel or a user."
  	when "denounce"
  		"#{Bold}email denounce <account name> [<target1> <target2> ...]#{Bold} => stop announcing an email account. If no targets are specified, all announcements of the email account will cease."
  	when "announcements"
  		"#{Bold}email announcements#{Bold} => lists all announcements currently active."	
  	when "check"
  		"#{Bold}email check <account name>#{Bold} => manually check for new mail on the specified account."
  	else
  		"email add|delete|list|show|set|announce|denounce|announcements|check"
  	end
  end
  
  # adds an account to the @accounts hash
  def add_account(m, params)
    if !@accounts.has_key?(params[:account_name])
      @accounts[params[:account_name]] = {
        :username => params[:username],
        :password => params[:password],		#TODO: encrypt this
        :server => params[:server],
        :port => params[:port]
        #:use_ssl => params[:use_ssl]
      }
        
      m.reply("Account #{Bold}#{params[:account_name]}#{Bold} added.")
    else
      m.reply("Account #{Bold}#{params[:account_name]}#{Bold} already exists. Please delete it first or use #{Bold}account set #{params[:account_name]} <parameter> <value>#{Bold} to modify it.")   
    end
  end
  
  # deletes an account from the @accounts hash
  def delete_account(m, params)
    if @accounts.has_key?(params[:account_name])
      @accounts.delete(params[:account_name])

      #also, delete all associated announcements
      @announcements.delete(params[:account_name])
      
      m.reply("Account #{Bold}#{params[:account_name]}#{Bold} deleted.")
    else
      m.reply("No account by that name.")
    end
  end
  
  # modifies accounts parameter given by params[:parameter]
  def modify_account(m, params)
    if @accounts.has_key?(params[:account_name])
      parameter = params[:parameter].to_sym
      
      if (@accounts[params[:account_name]].has_key?(parameter))
        @accounts[params[:account_name]][parameter] = params[:value]
          
        m.reply("Set #{Bold}#{params[:parameter]}#{Bold} of #{Bold}#{params[:account_name]}#{Bold} to #{Bold}#{params[:value]}#{Bold}.")
      else
        m.reply("'#{params[:parameter]}' is not a valid parameter.")
      end

    else
      m.reply("No account by that name.")
    end
  end
  
  # lists the @accounts hash
  def list_accounts(m, params)
    if @accounts.empty?
      m.reply("No accounts to list.")
    else
      m.reply @accounts.keys.join(", ")
    end
  end
  
  # pretty-printed information about an account
  def show_account(m, params)
    if @accounts.has_key?(params[:account_name])
      m.reply @accounts[params[:account_name]].to_a.map {|e| e.join(": ")}.join(", ")
    else
      m.reply("No account by that name.")
    end
  end
  
  # adds entries to the @announcements hash
  def add_announcements(m, params)
    if @announcements.has_key?(params[:account_name])
      @announcements[params[:account_name]] = @announcements[params[:account_name]] | params[:targets]
    else
      @announcements[params[:account_name]] = params[:targets]
    end
      
    targets_commalist = params[:targets].join(", ")
    m.reply("Now announcing #{Bold}#{params[:account_name]}#{Bold} to #{Bold}#{targets_commalist}#{Bold}.")
  end
  
  # deletes entries from the @announcements hash
  def delete_announcements(m, params)
    if @announcements.has_key?(params[:account_name])
    	
    	if params[:targets].empty?
    		# if no targets are specified, remove all targets
    		@announcements.delete(params[:account_name])
    		
    		m.reply("No longer announcing #{Bold}#{params[:account_name]}#{Bold}.")
    	else
    		@announcements[params[:account_name]] = @announcements[params[:account_name]] - params[:targets]
        	
          # remove hash key if no more targets are left
          @announcements.delete(params[:account_name]) if @announcements[params[:account_name]].empty?
          
          targets_commalist = params[:targets].join(", ")
          m.reply("No longer announcing #{Bold}#{params[:account_name]}#{Bold} to #{Bold}#{targets_commalist}#{Bold}.")
    
      end

    else
      m.reply("Account #{Bold}#{params[:account_name]}#{Bold} is not being announced.")
    end
  end
  
  # lists the @announcements hash
  def list_announcements(m, params)
      
    if @announcements.size > 0
      @announcements.each do |account_name, targets|
        targets_commalist = targets.join(", ")
        m.reply("Announcing #{Bold}#{account_name}#{Bold} to #{Bold}#{targets_commalist}#{Bold}")
      end
    else
      m.reply("Not announcing any email accounts.")
    end
  end
  
  # report new email
  def check_mail(m, params)	
    if @accounts.has_key?(params[:account_name])
      new_mail = fetch_mail(params[:account_name]) do |subject, from|
          m.reply "'#{subject}' from #{from}"
      end
  
      m.reply("No new mail for account #{Bold}#{params[:account_name]}#{Bold}.") if new_mail.empty?
    else
      m.reply("No account by that name.")
    end  
  end
  
  def fetch_mail(account_name, limit = 0)
    mails = []
    acc = @accounts[account_name]
    
    Net::POP3.start(acc[:server], acc[:port], acc[:username], acc[:password]) do |pop|
    
    	mails_to_fetch = pop.mails.reject {|m| mail_fetched?(m)}
    	
        # get all mails not yet fetched and process them
        mails_to_fetch.each do |mail|
        	
          if limit > 0 && mails.size >= limit
        		raise AnnouncementLimitReached.new(mails_to_fetch.size - mails.size) 
        	end
        	 
            header = mail.header
            subject = rfc2047_decode_to('utf-8', header.scan(/Subject: ([^\r\n]+)/).to_s)
            from = rfc2047_decode_to('utf-8', header.scan(/From: ([^\r\n]+)/).to_s)
            @fetched_mails << mail.unique_id
            yield(subject, from)
            
            mails << {:subject => subject, :from => from}
        end
    
    end
    
    return mails

  end
  
  # returns true if the unique id of parameter mail is in @fetched_mails (i.e. mail has been 
  # fetched), otherwise false
  def mail_fetched?(mail)
    @fetched_mails.include?(mail.unique_id)
  end
  
  def save
  	@registry[:fetched_mails] = @fetched_mails unless @fetched_mails.nil?
  	@registry[:accounts] = @accounts.dup unless @accounts.nil?
  	
  	# remove singleton methods by using dup, making the objects dumpable
  	unless @announcements.nil?
  		announcements = {}
  		
  		@announcements.each do |account_name,targets|
  			announcements[account_name] = targets.dup
  		end
  		
  		@registry[:announcements] = announcements
  	end
  end
  
  # Decodes a string, +from+, containing RFC 2047 encoded words into a target
  # character set, +target+. See iconv_open(3) for information on the
  # supported target encodings. If one of the encoded words cannot be
  # converted to the target encoding, it is left in its encoded form.
  #
  # Copyright (c) Sam Roberts <sroberts / uniserve.com> 2003
  def rfc2047_decode_to(target, from)
    out = from.gsub(WORD) do
      |word|
      charset, encoding, text = $1, $2, $3
      
      # B64 or QP decode, as necessary:
      case encoding
        when 'b', 'B'
          text = text.unpack('m*')[0]
    
        when 'q', 'Q'
          # RFC 2047 has a variant of quoted printable where a ' ' character
          # can be represented as an '_', rather than =32, so convert
          # any of these that we find before doing the QP decoding.
          text = text.tr("_", " ")
          text = text.unpack('M*')[0]
    
        # Don't need an else, because no other values can be matched in a
        # WORD.
      end
    
      # Convert
      #
      # Remember: Iconv.open(to, from)
      begin
        text = Iconv.open(target, charset) {|i| i.iconv(text)}
      rescue Errno::EINVAL, Iconv::IllegalSequence
        # Replace with the entire matched encoded word, a NOOP.
        text = word
      end
    end
  end
end

class AnnouncementLimitReached < RuntimeError
	attr :unfetched_mails
	
	def initialize(unfetched_mails)
		@unfetched_mails = unfetched_mails
	end
end

plugin = EmailPlugin.new
plugin.default_auth('*', false)
plugin.map 'email add :account_name :username :password :server [:port]', :action => 'add_account', :defaults => {:port => DEFAULT_PORT_POP3, :announced => false}
plugin.map 'email delete :account_name', :action => 'delete_account'
plugin.map 'email list', :action => 'list_accounts'
plugin.map 'email show :account_name', :action => 'show_account'
plugin.map 'email set :account_name :parameter :value', :action => 'modify_account'
plugin.map 'email announce :account_name *targets', :action => 'add_announcements'
plugin.map 'email denounce :account_name [*targets]', :action => 'delete_announcements'
plugin.map 'email announcements', :action => 'list_announcements'
plugin.map 'email check :account_name', :action => 'check_mail'
