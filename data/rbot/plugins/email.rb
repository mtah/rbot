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
require 'openssl/ssl'
require 'iconv'

# Regular expression for matching RFC2047 encoded strings
WORD = %r{=\?([!#$\%&'*+-/0-9A-Z\\^\`a-z{|}~]+)\?([BbQq])\?([!->@-~]+)\?=}

class EmailPlugin < Plugin
    
    def initialize
        super
        @fetched_mails = []				# keeps track of the unique ids of all fetched mails
                                        # to avoid re-fetching mails
                                        
        @accounts = {}					# all registered accounts
                                        # structure: {'account_name' => {
                                        # 					:username,
                                        # 					:password,
                                        # 					:host,	
                                        # 					:port,					
                                        # 			 	}
                                        #			 }
                                        
        @announcements = {}				# all announced accounts
                                        # structure: {'account_name' => ['#channel1', '#channel2']}
        
        @announcement_limit = 5			# announcement limit - don't announce any more mail at
                                        # the same time than this
                                        # NOT IMPLEMENTED
                                        
        @announcement_interval = 60		# time between annonuncements
        
        @is_announcing = false			# boolean
        
        # add announcement action to timer
        @bot.timer.add(@announcement_interval) {
        	unless @is_announcing	# do not start another announcement if bot already is announcing
	            
        		@is_announcing = true
        		
        		@announcements.each do |account_name, targets|
	            	targets.each {|target| @bot.say(target, "Announcing mail from #{account_name}")}
	                fetch_mail(account_name) do |subject,from|
	                    targets.each {|target| @bot.say(target, "MAIL: '#{subject}' from #{from}")}
	                end	
	            end
	        
	            @is_announcing = false
            end
	        
        }
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
            
            m.reply("Account #{params[:account_name]} added.")
        else
            m.reply("Account #{params[:account_name]} already exists. Please delete it first or use account set #{params[:account_name]} <parameter> <value>.")
            
        end
    end
    
    # deletes an account from the @accounts hash
    def delete_account(m, params)
        if @accounts.has_key?(params[:account_name])
            @accounts.delete(params[:account_name])
            
            m.reply("Account #{params[:account_name]} deleted.")
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
                
                m.reply("Set #{params[:parameter]} of #{params[:account_name]} to #{params[:value]}.")
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
        m.reply("Now announcing #{params[:account_name]} to #{targets_commalist}.")
    end
    
    # deletes entries from the @annonuncements hash
    def delete_announcements(m, params)
        if @announcements.has_key?(params[:account_name])
        	
        	if params[:targets].empty?
        		# if no targets are specified, remove all targets
        		@announcements.delete(params[:account_name])
        		
        		m.reply("Mo longer announcing #{params[:account_name]} at all.")
        	else
        		@announcements[params[:account_name]] = @announcements[params[:account_name]] - params[:targets]
            	
	            # remove hash key if no more targets are left
	            @announcements.delete(params[:account_name]) if @announcements[params[:account_name]].empty?
	            
	            targets_commalist = params[:targets].join(", ")
	            m.reply("No longer announcing #{params[:account_name]} to #{targets_commalist}.")
        
	        end
        else
            m.reply("Account #{params[:account_name]} is not being announced.")
        end
    end
    
    # lists the @annonuncements hash
    def list_announcements(m, params)
        
        if @announcements.size > 0
            @announcements.each do |account_name, targets|
                targets_commalist = targets.join(", ")
                m.reply("Announcing #{account_name} to #{targets_commalist}")
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
        
            m.reply("No new mail for account #{params[:account_name]}.") if new_mail.empty?
     
        else
            m.reply("No account by that name.")
        end
        
    end
    
    def fetch_mail(account_name)
        mails = []
        acc = @accounts[account_name]
        
        Net::POP3.start(acc[:server], acc[:port], acc[:username], acc[:password]) do |pop|
        
            # get all mails not yet fetched and process them
            pop.mails.reject {|m| mail_fetched?(m)}.each do |mail|
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

plugin = EmailPlugin.new
plugin.map 'email add :account_name :username :password :server :port', :action => 'add_account', :defaults => {:port => 110, :announced => false}
plugin.map 'email delete :account_name', :action => 'delete_account'
plugin.map 'email list', :action => 'list_accounts'
plugin.map 'email show :account_name', :action => 'show_account'
plugin.map 'email set :account_name :parameter :value', :action => 'modify_account'
plugin.map 'email announce :account_name *targets', :action => 'add_announcements'
plugin.map 'email denounce :account_name [*targets]', :action => 'delete_announcements'
plugin.map 'email announcements', :action => 'list_announcements'
plugin.map 'email check :account_name', :action => 'check_mail'
