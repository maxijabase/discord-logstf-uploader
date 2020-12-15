#include <sourcemod>
#include <json>
#include <steamworks>
#include <autoexecconfig>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.3"
#define PREFIX "[Discord Logs.TF]"

public Plugin myinfo =  {
	
	name = "Discord Logs.TF Uploader", 
	author = "ampere", 
	description = "Uploads the latest Logs.TF logs to a Discord Server.", 
	version = PLUGIN_VERSION, 
	url = "https://legacyhub.xyz"
	
};

/* Global Handles and Variables */

Database g_Database;
ConVar g_cvAPIURL, g_cvWebhook, g_cvDatabase;
int g_idb_logid, g_iapi_logid, g_iapi_log_time;
char g_cDiscord_Message[512], g_capi_map[32];
bool g_bIsSQLite = false;

/* On Plugin Start */

public void OnPluginStart() {
	
	AutoExecConfig_SetFile("DiscordLogs");
	AutoExecConfig_SetCreateFile(true);
	
	g_cvAPIURL = AutoExecConfig_CreateConVar("sm_discordlogs_api_url", "", "Logs.TF API URL");
	g_cvWebhook = AutoExecConfig_CreateConVar("sm_discordlogs_webhook", "", "Discord Webhook to broadcast new logs.");
	g_cvDatabase = AutoExecConfig_CreateConVar("sm_discordlogs_database", "storage-local", "Database config name.");
	
	CreateTimer(60.0, FetchAPIForLog, _, TIMER_REPEAT);
	
	ConnectToDatabase();
	
	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
	
}

/* Database Stuff */

public void ConnectToDatabase() {
	
	char database[32];
	g_cvDatabase.GetString(database, sizeof(database));
	Database.Connect(SQL_ConnectCallback, database);
	
}

public void SQL_ConnectCallback(Database db, const char[] error, any data) {
	
	if (db == null) {
		
		LogError("%s %s", PREFIX, error);
		return;
		
	}
	
	g_Database = db;
	CreateTable();
	
	// Get database driver to support MySQL as well
	
	char driver[16];
	g_Database.Driver.GetIdentifier(driver, sizeof(driver));
	g_bIsSQLite = driver[0] == 's' ? true : false;
	
	PrintToServer("%s Connection to database successful.", PREFIX);
	
}

public void CreateTable() {
	
	char createTablesQuery[512];
	
	// Only time where different query syntax is needed for MySQL support	
	
	if (g_bIsSQLite) {
		
		Format(createTablesQuery, sizeof(createTablesQuery), "CREATE TABLE IF NOT EXISTS discordlogs_ids(entry INTEGER PRIMARY KEY, log_id INTEGER);");
		
	}
	
	else {
		
		Format(createTablesQuery, sizeof(createTablesQuery), "CREATE TABLE IF NOT EXISTS discordlogs_ids(entry INT NOT NULL AUTO_INCREMENT, log_id INTEGER, PRIMARY KEY (entry));");
		
	}
	
	g_Database.Query(SQL_TablesCallback, createTablesQuery);
	
}

public void SQL_TablesCallback(Database db, DBResultSet results, const char[] error, any data) {
	
	// Error handling
	
	if (db == null || results == null) {
		
		LogError("%s TablesCallback: %s", PREFIX, error);
		delete results;
		return;
		
	}
	
	PrintToServer("%s Table creation successful.", PREFIX);
	delete results;
	
}

/* Logs.TF and Database */

public Action FetchAPIForLog(Handle timer) {
	
	// Fetch the Logs.TF API URL from the cvar
	
	char URL[256];
	g_cvAPIURL.GetString(URL, sizeof(URL));
	
	// Create the request with said URL
	
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, URL);
	
	SteamWorks_SetHTTPCallbacks(request, LogsAPI_Callback);
	SteamWorks_SendHTTPRequest(request);
	
}

public void LogsAPI_Callback(Handle request, bool failure, bool success, EHTTPStatusCode eStatusCode) {
	
	// Error handling
	
	if (failure || !success) {
		
		LogError("Error while querying the Logs.TF API.");
		delete request;
		return;
		
	}
	
	// API Response body handling
	
	int buffer;
	SteamWorks_GetHTTPResponseBodySize(request, buffer);
	char[] response = new char[buffer];
	SteamWorks_GetHTTPResponseBodyData(request, response, buffer);
	delete request;
	
	// JSON Parsing to extract latest log ID, time and map
	
	JSON_Object obj = json_decode(response);
	JSON_Array arrLogs = view_as<JSON_Array>(obj.GetObject("logs"));
	JSON_Object objLogs = arrLogs.GetObject(0);
	g_iapi_logid = objLogs.GetInt("id");
	g_iapi_log_time = objLogs.GetInt("date");
	objLogs.GetString("map", g_capi_map, sizeof(g_capi_map));
	
	// Filled API LOG ID, query database for DB LOG ID
	
	DatabaseLogQuery();
	
	delete obj;
	delete arrLogs;
	delete objLogs;
	
}

public Action DatabaseLogQuery() {
	
	// Create the query to fetch latest LOG ID stored in database
	
	char logIDquery[512];
	Format(logIDquery, sizeof(logIDquery), "SELECT log_id FROM discordlogs_ids ORDER BY entry DESC LIMIT 1;");
	
	// Send query
	
	g_Database.Query(SQL_LogIDCallback, logIDquery);
	
}

public void SQL_LogIDCallback(Database db, DBResultSet results, const char[] error, any data) {
	
	// Error handling
	
	if (db == null || results == null) {
		
		LogError("[DL] Error at LogIDCallback: %s", error);
		delete results;
		return;
		
	}
	
	// If there weren't results, it will just add the API LOG ID to the database (will happen once: when table is empty) 
	
	if (!results.FetchRow()) {
		
		AddLatestLog();
		BroadcastNewLog();
		delete results;
		return;
		
	}
	
	// The rest of the times, fetch the latest DB LOG ID, store it
	
	int logidCol;
	
	results.FieldNameToNum("log_id", logidCol);
	g_idb_logid = results.FetchInt(logidCol);
	
	// Compare DB LOG ID with the latest log the API declares
	
	CompareLogs();
	delete results;
	
}

public void CompareLogs() {
	
	if (g_idb_logid != g_iapi_logid) {
		
		AddLatestLog();
		BroadcastNewLog();
		
	}
	
	return;
	
}

public void AddLatestLog() {
	
	// Grab API LOG ID and stuff it into the database
	
	char latestLogQuery[512];
	Format(latestLogQuery, sizeof(latestLogQuery), "INSERT INTO discordlogs_ids (log_id) VALUES (%i);", g_iapi_logid);
	
	// Send query
	
	g_Database.Query(SQL_LatestLogCallback, latestLogQuery);
	
}

public void SQL_LatestLogCallback(Database db, DBResultSet results, const char[] error, any data) {
	
	// Error handling
	
	if (db == null || results == null) {
		
		LogError("[DL] Error at LatestLogCallback: %s", error);
		return;
		
	}
	
	PrintToServer("[DL] Latest log inserted into database successfully.");
	
}

/* Discord Broadcast */

public void BroadcastNewLog() {
	
	//Format Discord message with fancy stuff
	
	FormatDiscordMessage();
	
	// Grab the webhook link from the cvar
	
	char webhookURL[256];
	g_cvWebhook.GetString(webhookURL, sizeof(webhookURL));
	
	// Create and send HTTP requests
	
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, webhookURL);
	
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "content", g_cDiscord_Message);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Content-Type", "application/x-www-form-urlencoded");
	SteamWorks_SetHTTPCallbacks(request, DiscordBroadcast_Callback);
	SteamWorks_SendHTTPRequest(request);
	
}

public void DiscordBroadcast_Callback(Handle request, bool failure, bool success, EHTTPStatusCode eStatusCode) {
	
	// Error handling
	
	if (failure || !success) {
		
		LogError("Error while attempting to broadcast to Discord.");
		delete request;
		return;
		
	}
	
	PrintToServer("[DL] New log successfully broadcasted to Discord.");
	delete request;
	
}

public void FormatDiscordMessage() {
	
	// Formatting a char as the date using the log timestamp
	
	char date[32];
	FormatTime(date, sizeof(date), "%d/%m/%Y", g_iapi_log_time);
	
	// Formatting a char as the time using the log timestamp
	
	char time[32];
	FormatTime(time, sizeof(time), "%R", g_iapi_log_time);
	
	// Formatting final message
	
	Format(g_cDiscord_Message, sizeof(g_cDiscord_Message), ":calendar:  **%s - %s**\n:map:  **%s**\n:link:  https://logs.tf/%i", date, time, g_capi_map, g_iapi_logid);
	
} 