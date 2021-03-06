global.configs = require './configs'
global.mongoose = require 'mongoose'
session = require './lib/session'
api = require 'simple-api'
fs = require 'fs'
url = require 'url'
request = require 'request'
formidable = require 'formidable'
PUBNUB = require 'pubnub'

pubnub = PUBNUB.init
	publish_key: 'pub-c-84f589ef-0369-4651-8efd-74ae5a369e4f'
	subscribe_key: 'sub-c-188dbfd8-32a0-11e3-a365-02ee2ddab7fe'

v0 = null
kickoffTries = 0

session = session
	secret: configs.secret_key
	cookie:
		maxAge: 365 * 24 * 60 * 60 * 1000

kickoff = () ->
	kickoffTries++

	mongoose.connect configs.mongoURL, (err) ->
		if not err
			#Create API Server
			v0 = new api
				prefix: ["api", "v0"]
				host: null
				port: configs.port
				before: prepareAPIRequest
				fallback: apiFallback
				logLevel: 5

			oldRespond = v0.responses.respond
			v0.responses.respond = (res, message, statusCode) ->
				oldRespond res, message, statusCode


			#Load Controllers
			v0.Controller "keys", require "#{__dirname}/api/v0/controllers/keys.coffee"


			#Mock simple-api model format
			require "#{__dirname}/api/v0/models/keys.coffee"
			require "#{__dirname}/api/v0/models/users.coffee"

			console.log "#{configs.name} is now running at #{configs.host}:#{configs.port}"
		else if err & kickoffTries < 20
			console.log "Mongoose didn't work.  That's a bummer.  Let's try it again in half a second"
			setTimeout () ->
				kickoff()
			, 1000
		else if err
			console.log "Mongo server seems to really be down.  We tried 5 times.  Tough luck."

prepareAPIRequest = (req, res, controller) ->
	session req, res, () ->

apiFallback = (req, res) ->
	try
		session req, res, () ->

		urlParts = url.parse req.url, true

		if urlParts.pathname == "/login"
			fs.readFile './views/login.html', 'utf8', (err, data) ->
				if err
					v0.responses.internalError res
				else
					template = data
					template = template.replace "{{url}}", configs.url
					template = template.replace "{{app_id}}", configs.clef.app_id
					v0.responses.respond res, template
		else if urlParts.pathname == "/v1/login"
			fs.readFile './views/v1/login.html', 'utf8', (err, data) ->
				if err
					v0.responses.internalError res
				else
					template = data
					template = template.replace "{{url}}", configs.url
					template = template.replace "{{app_id}}", configs.clef.app_id
					v0.responses.respond res, template
		else if urlParts.pathname == "/clefCallback"
			handleClefCallback req, res
		else if urlParts.pathname == "/clefLogout"
			handleClefLogout req, res
		else if urlParts.pathname == "/logout"
			handleBrowserLogout req, res
		else if urlParts.pathname == "/check"
			handleAuthenticationCheck req, res
		else
			v0.responses.notAvailable res


	catch error
		v0.responses.internalError res
		console.log "API Fallback error!"
		console.log error

handleClefLogout = (req, res) ->
	urlParts = url.parse req.url, true

	form = new formidable.IncomingForm

	console.log "Parsing logout request"
	form.parse req, (err, fields, files) ->
		return console.log err if err
		console.log "Logout request parsed: #{fields}"
		data =
	 		app_id: configs.clef.app_id
	 		app_secret: configs.clef.app_secret
	 		logout_token: fields.logout_token

	 	console.log "Attempting Clef logout request"
	 	request.post
	 		url: 'https://clef.io/api/v1/logout'
	 		form: data
	 		(err, resp, body) ->
	 			if err
	 				msg = "ERROR in clef logout request: #{err}"
	 				console.log msg
	 				return v0.response.internalError res, msg

	 			console.log "Clef logout request recieved #{body}"
	 			try
			 		userInfo = JSON.parse body

		 			if err or !userInfo.success? or !userInfo.success
		 				console.log "Error getting clef user info", err
		 				v0.responses.notAuth res
		 			else
		 				Users = mongoose.model "Users"

		 				Users.getByIdentifier userInfo.clef_id, (err, existingUser) ->
		 					try
			 					if err or !existingUser.length
			 						console.log "Error finding user with Clef ID #{userInfo.clef_id}", err
			 						v0.responses.internalError res, "Error finding your user.  This probably isn't your fault.  Try again."
			 					else
			 						user = existingUser[0]
			 						user.logged_out_at = Date.now()

			 						user.save (err) ->
			 							if err
			 								console.log "Error saving user with Clef ID #{userInfo.clef_id}", err
			 								v0.responses.internalError res, "Error saving the user: #{err}"
			 							else
				 							console.log "User logged out"
				 							pubnub.publish
							                   channel: user.identifier
							                   message: "logout"

				 							v0.responses.respond res
		 					catch error
		 						v0.responses.internalError res
		 						console.log "Error logging user out of Cy"
		 						console.log error
		 		catch error
		 			v0.responses.internalError res
		 			console.log "Error handling response from Clef logout!"
		 			console.log error

handleBrowserLogout = (req, res) ->
	if req.session
		req.session = {}

	v0.responses.respond res


handleAuthenticationCheck = (req, res) ->
	try
		if req.session? and req.session.user
			Users = mongoose.model "Users"

			Users.getByIdentifier req.session.user.identifier, (err, existingUser) ->
				try
					if err or !existingUser.length
						v0.responses.respond res,
							user: false
					else
						user = existingUser[0]
						if user.logged_out_at > req.session.logged_in_at
							req.session = {}
							v0.responses.respond res,
								user: false
						else
							v0.responses.respond res,
								user: req.session.user.identifier
				catch error
					v0.responses.internalError res, "Error checking your user's session.  This probably isn't your fault."
					console.log "Error checking user's current session!"
					console.log error
		else
			v0.responses.respond res,
				user: false
	catch error
		v0.responses.internalError res
		console.log "Error handling authentication check!"
		console.log error


handleClefCallback = (req, res) ->
	try
		urlParts = url.parse req.url, true
		code = urlParts.query.code
		form =
			app_id: configs.clef.app_id
			app_secret: configs.clef.app_secret
			code: code

		request.post
			url: 'https://clef.io/api/v1/authorize'
			form: form
		, (err, resp, body) ->
			try
				clefResponse = JSON.parse body
				if err or not clefResponse.access_token?
					console.log "Error getting CLEF access token", err, clefResponse
					v0.responses.notAuth res
				else
					req.session.clefAccessToken = JSON.parse(body)['access_token']

					request.get "https://clef.io/api/v1/info?access_token=#{req.session.clefAccessToken}", (err, resp, body) ->
						try
							userInfo = JSON.parse body

							if err or !userInfo.success? or !userInfo.success
								console.log "Error getting clef user info", err
								v0.responses.notAuth res
							else
								Users = mongoose.model "Users"

								Users.getByIdentifier userInfo.info.id, (err, existingUser) ->
									if err
										v0.responses.internalError res, "Error finding your user.  This probably isn't your fault.  Try again."
									else if !existingUser.length
										#User doesn't exist.  Let's create one!
										Users.createWithIdentifier userInfo.info.id, (err, newUser) ->
											if err
												v0.responses.internalError res, "Error creating user.  This probably isn't your fault.  Try again."
											else
												#New user created!  Woohoo!
												req.session.logged_in_at = Date.now()
												req.session.user = newUser
												v0.responses.respond res, "<script type='text/javascript'>parent.postMessage({auth: true}, '*');</script>"
									else
										#user already exists.  Let's use that.
										req.session.logged_in_at = Date.now()
										req.session.user = existingUser[0]
										v0.responses.respond res, "<script type='text/javascript'>parent.postMessage({auth: true}, '*');</script>"
						catch error
							v0.responses.internalError res, "Error getting user information from Clef. This probably isn't your fault."
							console.log "Error parsing user response from Clef!"
							console.log error
			catch error
				v0.responses.internalError res, "Error getting authentication from Clef.  This probaby isn't your fault."
				console.log "Error parsing authentication response from Clef!"
				console.log error
	catch error
		v0.responses.internalError res
		console.log "Error handling Clef callback!"
		console.log error




kickoff()