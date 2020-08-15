# discord-logstf-uploader
 Uploads logs.tf latest logs to a discord server
 
 ## Usage
 
1- Drag the **addons** folder to your tf/ directory<br>
2- Do ``sm plugins load discord-logstf`` in your server console<br>
3- Configure your cvars in **tf/cfg/sourcemod/DiscordLogs.cfg** with the necessary information. Keep in mind a few things:
   - The *logs.tf* API link cannot contain spaces in the form of ``%20``, as they will get deleted and your link will get corrupted.
   - To get more information as to how to prepare an API link that suits your needs, visit http://logs.tf/about#json
   - An example link looks like this: ``http://logs.tf/api/v1/log?title=Legacy&limit=1&uploader=76561198179807307``
   
 ## Compiling dependencies
 
 - [sm-json](https://github.com/clugg/sm-json)
 - [SteamWorks](https://forums.alliedmods.net/showthread.php?t=229556)
 - [AutoExecConfig](https://github.com/Impact123/AutoExecConfig)
