#-- vim:sw=2:et
#++
#
# :title: Talk-like-a-pirate plugin
#
# Author:: Martin Häger <martin.haeger@gmail.com>
# Copyright:: (C) 2008 Martin Häger
# License:: GPLv2
#
# More documentation, if needed/wanted

require 'net/http'
require 'uri'

class PiratePlugin < Plugin
	def initialize
		debug "+ Loaded Pirate plugin."
		super
	end
	
	def pirate(m, params)
		res = Net::HTTP.post_form( 
				URI.parse('http://www.talklikeapirateday.com/translate/index.php'), 								{:text => params[:phrase]})
		pirate_says = res.body.gsub(/<\/?[^>]*>/, "").match(/(:)([[:print:]]*)/)[2]
		m.reply pirate_says
	end
	
	def help(plugin, topic="")
		"pirate <phrase> => say <phrase> as a pirate would say it"
	end

end

plugin = PiratePlugin.new
plugin.map 'pirate *phrase', :action => 'pirate'