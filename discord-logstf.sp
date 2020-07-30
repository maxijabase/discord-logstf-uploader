#include <sourcemod>
#include <json>
#include <steamworks>
#include <autoexecconfig>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =  {
	name = "Discord logs.tf uploader", 
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

/* On Plugin Start */

public void OnPluginStart() {
	
	AutoExecConfig_SetFile("DiscordLogs");
	AutoExecConfig_SetCreateFile(true);
	
	g_cvAPIURL = AutoExecConfig_CreateConVar("sm_discordlogs_api_url", "", "Logs.TF API URL");
	g_cvWebhook = AutoExecConfig_CreateConVar("sm_discordlogs_webhook", "", "Discord Webhook to broadcast new logs.");
	g_cvDatabase = AutoExecConfig_CreateConVar("sm_discordlogs_database", "storage-local", "Database config name.");
	
	HookEvent("teamplay_game_over", GameOverEvent);
	HookEvent("tf_game_over", GameOverEvent);
	
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
		LogError("[DL] Error at ConnectCallback: %s", error);
		return;
	}
	
	PrintToServer("[DL] Connection to database successful.");
	g_Database = db;
	CreateTable();
	
}

public void CreateTable() {
	
	char createTablesQuery[512];
	Format(createTablesQuery, sizeof(createTablesQuery), "CREATE TABLE IF NOT EXISTS discordlogs_ids(entry INTEGER PRIMARY KEY, log_id INTEGER);");
	g_Database.Query(SQL_TablesCallback, createTablesQuery);
	
}

public void SQL_TablesCallback(Database db, DBResultSet results, const char[] error, any data) {
	
	if (db == null || results == null) {
		LogError("[DL] Error at TablesCallback: %s", error);
		return;
	}
	
	PrintToServer("[DL] Table creation successful.");
	
}

/* Logs.TF and Database */

public void GameOverEvent(Event event, const char[] name, bool silent) {
	
	// Give the Logs.TF plugin some time to upload the logs
	CreateTimer(15.0, FetchAPIForLog);
	
}

public Action FetchAPIForLog(Handle timer) {
	
	// Fetch the Logs.TF API URL from the cvar
	char apiURL[256];
	g_cvAPIURL.GetString(apiURL, sizeof(apiURL));
	
	char URL[256];
	Format(URL, sizeof(URL), "%s", apiURL);
	
	// Create the request with said URL
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, URL);
	
	SteamWorks_SetHTTPCallbacks(request, LogsAPI_Callback);
	SteamWorks_SendHTTPRequest(request);
	
}

public void LogsAPI_Callback(Handle request, bool failure, bool success, EHTTPStatusCode eStatusCode) {
	
	// Error handling
	if (failure || !success || eStatusCode != k_EHTTPStatusCode200OK) {
		LogError("Error while querying the Logs.TF API.");
		delete request;
		return;
	}
	
	// API Response body handling
	int bufferSize;
	SteamWorks_GetHTTPResponseBodySize(request, bufferSize);
	char[] response = new char[bufferSize];
	SteamWorks_GetHTTPResponseBodyData(request, response, bufferSize);
	
	// JSON Parsing to extract latest log ID
	JSON_Object obj = json_decode(response);
	JSON_Array arrLogs = view_as<JSON_Array>(obj.GetObject("logs"));
	JSON_Object objLogs = arrLogs.GetObject(0);
	g_iapi_logid = objLogs.GetInt("id");
	g_iapi_log_time = objLogs.GetInt("date");
	objLogs.GetString("map", g_capi_map, sizeof(g_capi_map));
	
	// Filled API LOG ID, query database for DB LOG ID
	DatabaseLogQuery();
	delete request;
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
		return;
	}
	
	// If there weren't results, it will just add the API LOG ID to the database (will happen once: when table is empty) 
	if (!results.FetchRow()) {
		AddLatestLog();
		BroadcastNewLog();
		return;
	}
	
	// The rest of the times, fetch the latest DB LOG ID, store it
	int logidCol;
	
	results.FieldNameToNum("log_id", logidCol);
	g_idb_logid = results.FetchInt(logidCol);
	
	// Compare DB LOG ID with the latest log the API declares
	CompareLogs();
	
}

public void CompareLogs() {
	
	if (g_idb_logid == g_iapi_logid) {
		PrintToServer("[DL] Logs were equal! Not doing nothing.");
		return;
	}
	else {
		AddLatestLog();
		BroadcastNewLog();
	}
	
}

public void AddLatestLog() {
	
	// Grab API LOG ID and stuff it into the database
	char latestLogQuery[512];
	Format(latestLogQuery, sizeof(latestLogQuery), "INSERT INTO discordlogs_ids (log_id) VALUES (%i);", g_iapi_logid);
	
	g_Database.Query(SQL_LatestLogCallback, latestLogQuery);
	
}

public void SQL_LatestLogCallback(Database db, DBResultSet results, const char[] error, any data) {
	
	if (db == null || results == null) {
		LogError("[DL] Error at LatestLogCallback: %s", error);
		return;
	}
	
	PrintToServer("[DL] Latest log inserted into database successfully.");
	
}

/* Discord Broadcast */

public void BroadcastNewLog() {
	
	FormatDiscordMessage();
	
	char webhookURL[256];
	g_cvWebhook.GetString(webhookURL, sizeof(webhookURL));
	
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, webhookURL);
	
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "content", g_cDiscord_Message);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Content-Type", "application/x-www-form-urlencoded");
	
	SteamWorks_SetHTTPCallbacks(request, DiscordBroadcast_Callback);
	SteamWorks_SendHTTPRequest(request);
}

public void DiscordBroadcast_Callback(Handle request, bool failure, bool success, EHTTPStatusCode eStatusCode) {
	
	if (failure || !success) {
		LogError("Error while attempting to broadcast to Discord.");
		delete request;
		return;
	}
	
	PrintToServer("[DL] New log successfully broadcasted to Discord.");
	delete request;
}

public void FormatDiscordMessage() {
	
	char date[32];
	FormatTime(date, sizeof(date), "%d/%m/%Y", g_iapi_log_time);
	
	char time[32];
	FormatTime(time, sizeof(time), "%R", g_iapi_log_time);
	
	Format(g_cDiscord_Message, sizeof(g_cDiscord_Message), ":calendar:  **%s - %s**\n:map:  **%s**\n:link:  https://logs.tf/%i", date, time, g_capi_map, g_iapi_logid);
	
} 