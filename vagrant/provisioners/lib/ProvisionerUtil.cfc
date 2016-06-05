component {

	// A library for parsing YAML
	YAMLParser = new vagrant.provisioners.lib.YAMLParser()

	function getYAMLParser() {
		return YAMLParser;
	}

	/****************************************************
	*  Remove previous config
	****************************************************/
	function removePreviousConfig() {
		// Clean up old Nginx site configs
		if( directoryExists( '/etc/nginx/sites/' ) ) {
			directoryDelete( '/etc/nginx/sites/', true )
		}
		directoryCreate( '/etc/nginx/sites/' )

		if( directoryExists( '/var/www/assets' ) ) {
			directoryDelete( '/var/www/assets', true )
		}
		directoryCreate( '/var/www/assets' )

	}

	/****************************************************
	*  Get site configs by convention
	*
	*  Look for "VagrantConfig.yaml" files in
	*  the root of other repos cloned in the same dir
	***************************************************/
	function getSiteConfigs() {
		var configs = []
		// get a list of all the other repos checked out in the same dir as our Vagrant setup
		var repos = directoryList( '/vagrant-parent' )
		for( var repo in repos ) {
			var configDir = repo & '/VagrantConfig'
			// See if they have a "VagrantConfig" folder in them
			if( directoryExists( configDir ) ) {
				var configsInThisRepo = directoryList( configDir )
					configs.append( configsInThisRepo, true )
			}
		}


		return configs
	}

	/****************************************************
	*  Default config keys
	***************************************************/
	function defaultConfig( config ) {
		// Convert to CFML struct
		config = {}.append( config )

		// Default all the keys we care about
		config.name = config.name ?: listLast( config[ '__configFile__' ], '/\' )
		config.webroot = config.webroot ?: ''
		config.hosts = config.hosts ?: []
		config.cfmappings = config.cfmappings ?: []
		config.datasources = config.datasources ?: []

		return config;
	}

	/****************************************************
	*  Setup Nginx server
	****************************************************/
	function configureNginx( config, siteConfigPath ) {
		if( arrayLen( config['hosts'] ) ) {
			var webRoot = convertPath( config['webroot'], siteConfigPath )

			// Read in our Nginx template file
			var siteTemplate = fileRead( '/vagrant/configs/site-template.conf' )
			// Swap out the dynamic parts
			siteTemplate = replaceNoCase( siteTemplate, '@@webroot@@', webRoot )
			siteTemplate = replaceNoCase( siteTemplate, '@@hosts@@', arrayToList( config['hosts'], ' ' ) )
			siteTemplate = replaceNoCase( siteTemplate, '@@name@@', slugifySiteName( config[ 'name' ] ) )

			// Write it back out
			var fileName = '/etc/nginx/sites/#slugifySiteName( config[ 'name' ] )#.conf'
			fileWrite( fileName, siteTemplate )

			_echo( "Added Nginx site #fileName#" )
		} else {
			_echo( "#config[ 'name' ]# doesn't have any hosts specified, so skipping Nginx config" )
		}
	}

	/****************************************************
	*  Create CF mappings in the server
	*
	*  <mapping
	*		inspect-template=""
	*		physical="/var/www"
	*		primary="physical"
	*		toplevel="true"
	*		virtual="/foo"/>
	*
	****************************************************/
	function configureMappings( config, siteConfigPath ) {
		// Adding this to the server context.   Might need to add to the web context, but would need to
		// do some magic since WEB-INFs wouldn't be created yet
		serverXML = XMLParse( fileRead( '/opt/lucee/lib/lucee-server/context/lucee-server.xml' ) )
		for( var mapping in config[ 'cfmappings' ] ) {
			// Convert to CFML struct
			mapping = {}.append( mapping )

			// Only process if proper keys are defined
			if( !mapping.keyExists( 'virtual' ) && !mapping.keyExists( 'physical' ) ) {
				continue;
			}

			var found = false

			// Check for existing
			for( var child in serverXML.cfLuceeConfiguration.mappings.XmlChildren ) {
				if( child.xmlName == 'mapping' && child.XmlAttributes.virtual == trim( mapping[ 'virtual' ] ) ) {
					found = true
					break;
				}
			}

			if( found ) { continue; }

			var newMapping = XmlElemNew( serverXML, 'mapping' )
			newMapping.XmlAttributes[ 'inspect-template' ] = ''
			newMapping.XmlAttributes[ 'physical' ] = convertPath( trim( mapping[ 'physical' ] ), siteConfigPath )
			newMapping.XmlAttributes[ 'primary' ] = 'physical'
			newMapping.XmlAttributes[ 'toplevel' ] = 'true'
			newMapping.XmlAttributes[ 'virtual' ] = trim( mapping[ 'virtual' ] )

			serverXML.cfLuceeConfiguration.mappings.XmlChildren.append( newMapping )

			fileWrite( '/opt/lucee/lib/lucee-server/context/lucee-server.xml', toString( serverXML )  )

			_echo( "Added CF Mapping #mapping[ 'virtual' ]#" )

		}

	}

	/****************************************************
	*  Create CF data sources in the server
	*
	*  <data-source
	*  		allow="511"
	*  		blob="false"
	*  		class="com.microsoft.jdbc.sqlserver.SQLServerDriver"
	*  		clob="false"
	*  		connectionTimeout="1"
	*  		custom="DATABASENAME=myDB&amp;sendStringParametersAsUnicode=true&amp;SelectMethod=direct"
	*  		database="myDB"
	*  		dbdriver="MSSQL"
	*  		dsn="jdbc:sqlserver://{host}:{port}"
	*  		host="localhost"
	*  		metaCacheTimeout="60000"
	*  		name="myDS"
	*  		password="encrypted:8cc95a59f1d667fa5cb736e6c3363465"
	*  		port="1433"
	*  		storage="false"
	*  		username="bob"
	*  		validate="false"
	*  		/>
	*
	****************************************************/
	function configureDataSources( config, vagrantParentPath ) {
		// Adding this to the server context.   Might need to add to the web context, but would need to
		// do some magic since WEB-INFs wouldn't be created yet
		serverXML = XMLParse( fileRead( '/opt/lucee/lib/lucee-server/context/lucee-server.xml' ) )
		for( var datasource in config[ 'datasources' ] ) {
			datasource = getDefaultDatasource().append( datasource )
			var found = false

			// Check for existing
			for( var child in serverXML.cfLuceeConfiguration[ 'data-sources' ].XmlChildren ) {
				if( child.xmlName == 'data-source' && child.XmlAttributes.name == trim( datasource.name ) ) {
					found = true
					break;
				}
			}

			if( found ) { continue; }

			// Lookup DB login credentials.  Will return a struct with empty strings if not found.
			dbCreds = getDBCreds( datasource.name, vagrantParentPath )

			var newDatasource = XmlElemNew( serverXML, 'data-source' )
			newDatasource.XmlAttributes[ 'name' ] = datasource.name
			newDatasource.XmlAttributes[ 'blob' ] = datasource.blob
			newDatasource.XmlAttributes[ 'class' ] = datasource.class
			newDatasource.XmlAttributes[ 'clob' ] = datasource.clob
			newDatasource.XmlAttributes[ 'connectionTimeout' ] = datasource.connectionTimeout
			newDatasource.XmlAttributes[ 'custom' ] = datasource.custom
			newDatasource.XmlAttributes[ 'database' ] = datasource.database
			newDatasource.XmlAttributes[ 'dbdriver' ] = datasource.dbdriver
			newDatasource.XmlAttributes[ 'dsn' ] = datasource.dsn
			newDatasource.XmlAttributes[ 'host' ] = datasource.host
			newDatasource.XmlAttributes[ 'metaCacheTimeout' ] = datasource.metaCacheTimeout
			newDatasource.XmlAttributes[ 'allow' ] = datasource.allow
			newDatasource.XmlAttributes[ 'password' ] = dbCreds.password
			newDatasource.XmlAttributes[ 'port' ] = datasource.port
			newDatasource.XmlAttributes[ 'storage' ] = datasource.storage
			newDatasource.XmlAttributes[ 'username' ] = dbCreds.username
			newDatasource.XmlAttributes[ 'validate' ] = datasource.validate

			serverXML.cfLuceeConfiguration[ 'data-sources' ].XmlChildren.append( newDatasource )

			fileWrite( '/opt/lucee/lib/lucee-server/context/lucee-server.xml', toString( serverXML )  )

			_echo( "Added CF data source #datasource.name#" )

		}

	}

	// All the possible data source keys
	function getDefaultDatasource() {
		return {
			allow="511",
			blob="false",
			class="com.microsoft.jdbc.sqlserver.SQLServerDriver",
			clob="false",
			connectionTimeout="1",
			custom="",
			database="",
			dbdriver="MSSQL",
			dsn="jdbc:sqlserver://{host}:{port}",
			host="localhost",
			metaCacheTimeout="60000",
			name="",
			port="1433",
			storage="false",
			validate="false"
		};
	}

	/****************************************************
	*  Look up DB credentials in the DBCredentials.yaml
	*  file.  If they aren't found, empty string will
	*  be returned and a message output.
	****************************************************/
	function getDBCreds( required name, vagrantParentPath ) {
		var DBCredDir = '/vagrant-parent/VagrantCredentials/'
		var DBCredFile = DBCredDir & 'DB.yaml'
		var DBCredFileFull = replaceNoCase( DBCredFile, '/vagrant-parent', vagrantParentPath )
		var results = { 'username': '', 'password': '' }

		// If our DB Credentials file doesn't exist, create it empty
		if( !fileExists( DBCredFile ) ) {
			directoryCreate( path=DBCredDir, createPath=true, ignoreExists=true )
			fileWrite( DBCredFile, '' )
		}

		// Read and parse the DB.yaml file. If it's empty, we'll get {} back
		try {
			var DBCreds = getYAMLParser().yamlToCfml( fileRead( DBCredFile ) )
		} catch ( var e ) {
			// I don't want a bad DB.yaml file to kill the entire setup.
			_echo( "Error parsing [#DBCredFileFull#]" )
			_echo( e.message & ' '  & e.detail )
			// Just return an empty username and password
			return results;
		}

		// Of there are credentials stored for this datasource...
		if( structKeyExists( DBCreds, name )
			&& structKeyExists( DBCreds[ name ], 'username' )
			&& len( trim( DBCreds[ name ][ 'username' ] ) )
			&& structKeyExists( DBCreds[ name ], 'password' )
			&& len( trim( DBCreds[ name ][ 'password' ] ) )
		) {
			// Get and return them
			results.username = DBCreds[ name ][ 'username' ]
			results.password = DBCreds[ name ][ 'password' ]
			return results;
		}

		// If we got here, it means the developer hasn't populated the credientials.
		// Yell at them a bit in the output.
		var message = '## Please configure your DB credentials for "#name#" in [#DBCredFileFull#]'
		_echo( '' )
		_echo( repeatString( '##', len( message) + 3 ) )
		_echo( message )
		_echo( '## and re-provision the VM to pick up the changes' )
		_echo( repeatString( '##', len( message) + 3 ) )
		_echo( '' )

		// Add this data source to the YAML file as a convience to help the developer fill it out.
		DBCreds[ name ] = results
		// Serialize to YAML and write it back out.
		fileWrite( DBCredFile, getYAMLParser().CFMLToYAML( DBCreds ) )

		// Return empty username and password.
		return results;

	}


	/****************************************************
	*  Setup hosts in the VM's host file.
	*  The hostmachine's host file is handled by the
	*  Vagrant hostupdater plugin in the VagrantFile
	****************************************************/
	function configureHosts( config ) {

		// Read in our Linux hosts files
		var hosts = fileRead( '/etc/hosts' )

		for( var host in config[ 'hosts' ] ) {
			if( ! reFindNoCase( '\s*#host#\s*$', hosts ) ) {
				hosts &= '#chr( 10 )#127.0.0.1	#host#'
				_echo( "Added #host# to /etc/hosts" )
			}
		}

		// Write it back out
		fileWrite( '/etc/hosts', hosts )

	}

   /****************************************************
   *  Reset webroots to CF config file.
   *****************************************************/
   function resetColdFusionServerXML() {
      serverXML = XMLParse( fileRead( '/opt/coldfusion11/cfusion/runtime/conf/server.xml' ) )
      var contextXmlElement = serverXML.Server.Service.Engine.Host.Context
      contextXmlElement.XmlAttributes["aliases"] = "/CFIDE=/opt/coldfusion11/cfusion/wwwroot/CFIDE,/WEB-INF=/opt/coldfusion11/cfusion/wwwroot/WEB-INF"

      fileWrite( '/opt/coldfusion11/cfusion/runtime/conf/server.xml', toString( serverXML ) )
   }

   /****************************************************
   * Append webroots to CF config file
   *****************************************************/
   function appendWebRootToColdFusionServerXML( config, siteConfigPath ) {
      var contextAlias = config[ 'name' ]
      var contextValue = convertPath( config[ 'webroot' ], siteConfigPath )

      serverXML = XMLParse( fileRead( '/opt/coldfusion11/cfusion/runtime/conf/server.xml' ) )

      var contextXmlElement = serverXML.Server.Service.Engine.Host.Context
      var originalValueContextAttribute = contextXmlElement.XmlAttributes["aliases"]
      var newValueContextAttribute = originalValueContextAttribute & ",/"  & contextAlias & "=" & contextValue
      contextXmlElement.XmlAttributes["aliases"] = newValueContextAttribute

      fileWrite( '/opt/coldfusion11/cfusion/runtime/conf/server.xml', toString( serverXML ) )

      _echo ( "Added #contextAlias# to ColdFusion webroot" )
   }

	/****************************************************
	*  Write dynamic default index that
	*  lists out the configured sites
	****************************************************/
	function writeDefaultIndex( siteConfigs ) {
		var defaultSiteIndex = fileRead( '/var/wwwDefault/index.cfm' )

		sortedConfigs = siteConfigs.sort( 'text', 'asc', 'name' )

		saveContent variable='local.siteList' {
			include '/var/wwwDefault/siteList.cfm';
		}
		local.siteList = replaceNoCase( local.siteList, '##', '####', 'all' )
		defaultSiteIndex = replaceNoCase( defaultSiteIndex, '@@siteList@@', siteList )
		fileWrite( '/var/www/index.cfm', defaultSiteIndex )

		directoryCopy( '/var/wwwDefault/assets', '/var/www/assets', true )
	}

	/****************************************************
	*  Clean up site name for file system
	****************************************************/
	function slugifySiteName( str ) {
		var slug = lcase(trim(arguments.str))
		slug = reReplace(slug,"[^a-z0-9-\s]","","all")
		slug = trim ( reReplace(slug,"[\s-]+", " ", "all") )
		slug = reReplace(slug,"\s", "-", "all")
		return slug
	}

	/****************************************************
	*  Custom echo that also appends to
	*  install log and adds line feed
	****************************************************/
	function _echo( message ) {
		message &= chr( 10 )
		echo( message )
	}

	/****************************************************
	*  Convert path segment relative to
	*  repo root into a full path
	****************************************************/
	function convertPath( path, configPath ) {
		// Standardize and remove leading/trailing slashes
		var path = listChangeDelims( path, '/', '/\' )
		// Root of the repo which the path above is relative to
		var repoRoot = reReplaceNoCase( configPath, 'VagrantConfig/[^\.]*.yaml', '' )
		return repoRoot & path
	}

}
