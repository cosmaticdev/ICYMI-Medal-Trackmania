// thank you to the following for contributing a portion of the following script
// https://github.com/Phlarx/tm-checkpoint-counter
// https://github.com/ezio416/tm-current-effects
// https://github.com/RuurdBijlsma/tm-split-speeds

void Main() {
    // allow the program to check for medal until a connection can be made
    while (true) {

        Request@ req = Request('http://localhost:12665/api/v1/context/submit', '', {});

        print("Checking if Medal is active");
        print('Waiting for Medal...');
        sleep(1000);

        if (req.req.Finished()) {
            print('Medal is active and ready to go');
            break;
        } else {
            print('Medal is offline! Your clips will not work. Retrying in 30 seconds');
            sleep(1000 * 30);
        }
    }

    Intercept(); //start the process to listen for collected checkpoints
    while (true) {
        auto app = GetApp();
        if (app is null) {
            yield();
            continue;
        }

        auto playground = cast<CSmArenaClient>(GetApp().CurrentPlayground);
		
        // make sure the player is in game, fully loaded, and playing; can't have the program mess this part up by trying to fetch unloaded data
		if(playground is null
			|| playground.Arena is null
			|| playground.Map is null
			|| playground.GameTerminals.Length <= 0
			|| playground.GameTerminals[0].UISequence_Current != CGamePlaygroundUIConfig::EUISequence::Playing
			|| cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer) is null) {
		} else {

            CGameCtnChallenge@ map = app.RootMap;

            if (map !is null) {
                currentMapId = map.EdChallengeId; // get the map the player is on 
                if (currentMapId != lastMapId) {
                    print("Switched to new map: " + currentMapId);
                    lastMapId = currentMapId;
                    checkpointCount = GetCheckpointCount(); // get how many checkpoints are in the map
                    print("This map has " + checkpointCount + " checkpoints");
                    hasFinished = false;

                    CGamePlayerInfo@ profile = app.LocalPlayerInfo;
                    playerId = profile.IdName;
                    playerName = profile.Name;
                    // can find profile at https://trackmania.io/#/player/{IdName}

                    NetStuff('http://localhost:12665/api/v1/context/submit', '{"localPlayer": {"playerId": "' + playerId + '", "playerName": "' + playerName + '"}, "globalContextData":{"mapID": "' + currentMapId + '"}}'); // let medal know the user switched maps 
                }
            }
        }

        yield();
    }
}

void Update(float dt) {

    CGameCtnApp@ app = GetApp();
    if (app is null || app.CurrentPlayground is null) return;
    CGamePlayground@ playground = cast<CGamePlayground>(app.CurrentPlayground);
    if (playground is null) return;

    // Detect the player starting a race 
    try {
        auto player = cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer);
        if (player !is null) {
            auto scriptPlayer = cast<CSmScriptPlayer@>(player.ScriptAPI);
            auto post = scriptPlayer.Post;
            if (!trackStart && post == CSmScriptPlayer::EPost::Char) {
                trackStart = true;
            } else if (trackStart && post == CSmScriptPlayer::EPost::CarDriver) {
                trackStart = false;
            }
        }
    } catch {
        trackStart = false;
    }


    if (!trackStart) {
        if (GetRunningTime() == 0) {
            print("Race has started!");
            hasFinished = false;
            checkpoints = 0;
            NetStuff('http://localhost:12665/api/v1/event/invoke', '{"eventId": "race_start", "eventName": "Race Started"}');
            // if API functionality is added, this is where the call is made to start recording
        }
    }

    // check for the player to have finished the race 
    if (playground.GameTerminals.Length > 0 && playground.GameTerminals[0].UISequence_Current == CGamePlaygroundUIConfig::EUISequence::Finish && !hasFinished) {
        // the final checkpoint is the finish line, so use the timestamp it was reached
        // this is only accurate to 2 decimals, instead of trackmanias recorded accuracy of 3 decimals
        uint minutes = lastCheckpointTime / 60000;
        uint seconds = (lastCheckpointTime % 60000) / 1000;
        uint milliseconds = lastCheckpointTime % 1000;
        print("Track finished at " + minutes + ":" + seconds + "." + milliseconds);
        hasFinished = true;
        NetStuff('http://localhost:12665/api/v1/event/invoke', '{"eventId": "race_finish", "eventName": "Race Finished"}');
        // if API functionality is added, this is where the call is made to stop recording
    }
}

bool trackStart = true; // has the race started
bool hasFinished = true; // has the race ended 
bool intercepting = false; // are we watching the checkpoints
bool wasFinish = false; // was that last checkpoint the finish
uint checkpoints = 0; // how many checkpoints have we crossed
uint checkpointCount = 0; // how many checkpoints does this map have
string lastMapId = ""; // what map were we playing
uint lastCheckpointTime = 0; // when did we cross the last finish line
string currentMapId = ""; // what map are we playing right now
string playerId = "";
string playerName = "";

// watches the checkpoints to see if we've crossed any of them
void Intercept() {
    if (intercepting) {
        warn("Intercept called, but it's already running!");
        return;
    }

    if (GetApp().CurrentPlayground is null)
        return;

    trace("Intercept starting for \"LayerCustomEvent\"");

    try {
        Dev::InterceptProc("CGameManiaApp", "LayerCustomEvent", _Intercept);
        intercepting = true;
    } catch {
        warn("Intercept error: " + getExceptionInfo());
    }
}

bool _Intercept(CMwStack &in stack, CMwNod@ nod) {
    try {
        CaptureEvent(stack.CurrentWString(1), stack.CurrentBufferWString());
    } catch {
        warn("Exception in Intercept: " + getExceptionInfo());
    }

    return true;
}

void CaptureEvent(const string &in type, MwFastBuffer<wstring> &in data) {
    if (type == "TMGame_RaceCheckpoint_Waypoint") {  // make sure the event was a checkpoint
        checkpoints += 1;
        uint time = GetRunningTime();
        lastCheckpointTime = time;
        uint minutes = time / 60000;
        uint seconds = (time % 60000) / 1000;
        uint milliseconds = time % 1000;
        if (checkpoints == checkpointCount+1) {
            wasFinish = true;
        } else {
            wasFinish = false;
        }
        if (!wasFinish) {
            print("Hit checkpoint #" + checkpoints + " at " + minutes + ":" + seconds + "." + milliseconds);
        }
        // this is only accurate to 2 decimals, instead of trackmanias recorded accuracy of 3 decimals

        CGameCtnApp@ app = GetApp();
        if (app is null || app.CurrentPlayground is null) return;
        CGamePlayground@ playground = cast<CGamePlayground>(app.CurrentPlayground);
        if (playground is null) return;

        NetStuff('http://localhost:12665/api/v1/context/submit', '{"localPlayer": {"playerId": "' + playerId + '", "playerName": "' + playerName + '"},"globalContextData":{"mapID": "' + currentMapId + '", "checkpoint": ' + checkpoints + ', "timeReached": ' + time + ', "wasFinish": "' + wasFinish + '"}}');
        // let medal know we hit a checkpoint and when we hit it. Also let medal know if that was the finish line or not 
    }
}

// get the current race time
uint GetRunningTime() {
    try {
        auto playground = cast<CSmArenaClient>(GetApp().CurrentPlayground);
        auto player = cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer);
        auto scriptPlayer = player is null ? null : cast<CSmScriptPlayer>(player.ScriptAPI);
        auto playgroundScript = cast<CSmArenaRulesMode@>(GetApp().PlaygroundScript);

        if (playgroundScript is null)
            // Online
            return GetApp().Network.PlaygroundClientScriptAPI.GameTime - scriptPlayer.StartTime;
        else
            // Solo
            return playgroundScript.Now - scriptPlayer.StartTime;
    } catch {
        return -1;
    }
}

// get the amount of checkpoints in the race
uint GetCheckpointCount() {
    auto playground = cast<CSmArenaClient>(GetApp().CurrentPlayground);
    MwFastBuffer<CGameScriptMapLandmark@> landmarks = playground.Arena.MapLandmarks;

    uint _maxcheckpoint = 0;
    array<int> links = {};
    for(uint i = 0; i < landmarks.Length; i++) {
        if(landmarks[i].Waypoint !is null && !landmarks[i].Waypoint.IsFinish && !landmarks[i].Waypoint.IsMultiLap) {
            // we have a checkpoint, but we don't know if it is Linked or not
            if(landmarks[i].Tag == "Checkpoint") {
                _maxcheckpoint += 1;
            } else if(landmarks[i].Tag == "LinkedCheckpoint") {
                if(links.Find(landmarks[i].Order) < 0) {
                    _maxcheckpoint += 1;
                    links.InsertLast(landmarks[i].Order);
                }
            } else {
                // this waypoint looks like a checkpoint, acts like a checkpoint, but is not called a checkpoint.
                _maxcheckpoint += 1; //whatever, guess i'll just call it a checkpoint
            }
        }
    }

    return _maxcheckpoint;
}

// used for sending post requests to medal
void NetStuff(string url, string payload) {
    // Define headers
    dictionary headers = {
        {"publicKey", "pub_fkwjWOeMfGHeGXHI8wNYwg1lkTcTAflk"} // medal public key
    };

    // Send request
    Request@ req = Request(url, payload, headers);
}

class Request {
    Net::HttpRequest@ req;

    Request(const string &in url, const string &in body, dictionary@ headers) {
        @req = Net::HttpRequest();
        req.Method = Net::HttpMethod::Post; // Set HTTP method to POST
        req.Url = url;
        req.Body = body;
        req.Headers = headers;

        req.Start(); // Send the request
        startnew(CoroutineFunc(this.run));
    }

    private void run() {
        while (!this.req.Finished()) {
            yield();
        }
        //print(req.String());
    }
}