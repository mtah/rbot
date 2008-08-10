#-- vim:sw=2:et
#++
#
# :title: Al Bhed <=> English translator
#
# Author:: Martin Häger <martin.haeger@gmail.com>
# Copyright:: (C) 2008 Martin Häger
# License:: GPLv2
#
# Usage: albhed <phrase> => translates the English <phrase> to Al Bhed
#		 english <phrase> => translates the Al Bhed <phrase> to English
#

class AlBhedPlugin < Plugin 
	
	# Al Bhed character map (the character positions correspond to the English alphabet)
	@@Albhed_character_map = "ypltavkrezgmshubxncdijfqowYPLTAVKREZGMSHUBXNCDIJFQOW"
	
	# English character map (the character positions correspond to the Al Bhed alphabet)
	@@English_character_map = "epstiwknuvgclrybxhmdofzqajEPSTIWKNUVGCLRYBXHMDOFZQAJ"	
	
	def initialize
		debug "+ Loaded Al Bhed plugin."
		super
	end

	def english_to_albhed(m, params)
		source = params[:phrase].to_s
		m.reply source.tr("a-zA-Z", @@Albhed_character_map)
	end
	
	def albhed_to_english(m, params)
		source = params[:phrase].to_s
		m.reply source.tr("a-zA-Z", @@English_character_map)
	end
	
	def help(plugin, topic = "")
		"albhed <phrase> => translates the English <phrase> to Al Bhed. " + 
		"english <phrase> => translates the Al Bhed <phrase> to English."
	end
end	

plugin = AlBhedPlugin.new

plugin.map 'albhed *phrase', :action => 'english_to_albhed'
plugin.map 'english *phrase', :action => 'albhed_to_english'