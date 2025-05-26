void Main() {
    // allow the program to check for medal until a connection can be made
    while (true) {

        // ping medal's local port
        Request@ req = Request('http://localhost:12665/api/v1/context/submit', '', {});

        trace('Waiting for Medal...');
        sleep(1000);

        if (req.req.Finished()) {
            trace('Connection made with Medal API');
            break;
        } else {
            warn('Medal is offline! Your clips will not work. Retrying in 30 seconds');
            sleep(1000 * 30);
        }
    }

    MLHook::RegisterMLHook(ClipHook(), "RaceMenuEvent_InvokeMedalClip", true); // make a hook to catch medal clip events

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
			|| cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer) is null) { lastMapId = "";
		} else {

            CGameCtnChallenge@ map = app.RootMap;

            if (map !is null) {
                currentMapId = map.EdChallengeId; // get the map the player is on 
                if (currentMapId != lastMapId) {
                    if (!intercepting) {
                        Intercept(); //start the process to listen for collected checkpoints
                    }
                    trace("Switched to new map: " + currentMapId);
                    lastMapId = currentMapId;
                    checkpointCount = GetCheckpointCount(); // get how many checkpoints are in the map
                    hasFinished = false;

                    CGamePlayerInfo@ profile = app.LocalPlayerInfo;
                    playerId = profile.IdName;
                    playerName = profile.Name;
                    // can find profile at https://trackmania.io/#/player/{playerId}

                    NetStuff('http://localhost:12665/api/v1/context/submit', '{"localPlayer": {"playerId": "' + playerId + '", "playerName": "' + playerName + '"}, "globalContextData":{"mapID": "' + currentMapId + '"}}'); // let medal know the user switched maps 
                    loadMenu(); // load the medal button in to the ui
                }
            } else {
                lastMapId = "";
            }
        }

        yield();
    }
}

// handles user clicking clip button in game
uint timeSinceClipMS = 0; // block user from spamming loads of clips at once, only allow one every 3 seconds or so
class ClipHook : MLHook::HookMLEventsByType {
    ClipHook() {
        super("RaceMenuEvent_InvokeMedalClip");
    }

    void OnEvent(MLHook::PendingEvent@ event) override {
        if (timeSinceClipMS > 3000) {
            print("Saving clip with Medal");
            timeSinceClipMS = 0;
        }
    }
}


void Update(float dt) {

    CGameCtnApp@ app = GetApp();
    CGamePlayground@ playground = cast<CGamePlayground>(app.CurrentPlayground);
    if (playground == null) { return; }

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

    if (app.Viewport.AverageFps <= 0.0f)
        return;

    if (!trackStart) {
        if (GetRunningTime() == 0) {
            hasFinished = false;
            checkpoints = 0;
            isPlayerAFK = false;
            AFKTimeMS = 0;
            timeSinceClipMS = 99999; // allowing the user to clip asap once the race is over
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
        trace("Track finished at " + minutes + ":" + seconds + "." + milliseconds);
        hasFinished = true;
        NetStuff('http://localhost:12665/api/v1/event/invoke', '{"eventId": "race_finish", "eventName": "Race Finished"}');
        // if API functionality is added, this is where the call is made to stop recording
    }

    // watch player speed to detect AFK
    auto visState = VehicleState::ViewingPlayerState();
    if (visState is null) return;
    
    if (!hasFinished) {
        float speed = visState.WorldVel.Length() * 3.6;
        if (isPlayerAFK && speed > 5) {
            isPlayerAFK = false;
            AFKTimeMS = 0;
            trace("Player returned from AFK");
            NetStuff('http://localhost:12665/api/v1/event/invoke', '{"eventId": "afk_return", "eventName": "Returned from AFK"}');
            // if API functionality is added, this is where the call is made to resume recording
        } else if (speed < 5 && !isPlayerAFK) {
            AFKTimeMS += int(1000.0f / app.Viewport.AverageFps);
        }

        // 1500ms = 15s
        if (AFKTimeMS >= 15000 && !isPlayerAFK) { 
            isPlayerAFK = true;
            trace("Player went AFK");
            NetStuff('http://localhost:12665/api/v1/event/invoke', '{"eventId": "afk_start", "eventName": "Went AFK"}');
            // if API functionality is added, this is where the call is made to stop recording
        }
    }

    if (hasFinished) {
        timeSinceClipMS += int(1000.0f / app.Viewport.AverageFps);
    }
}

void loadMenu() {
    CTrackMania@ App = cast<CTrackMania@>(GetApp());
    CTrackManiaNetwork@ Network = cast<CTrackManiaNetwork@>(App.Network);
    CGameManiaAppPlayground@ CMAP = Network.ClientManiaAppPlayground;

    if (CMAP !is null && CMAP.UILayers.Length > 1) {

        for (int i = CMAP.UILayers.Length - 1; i >= 0; i--) {
            CGameUILayer@ Layer = CMAP.UILayers[i];
            if (Layer is null)
                continue;

            if (string(Layer.ManialinkPage).Trim().SubStr(0, 50).Contains("_EndRaceMenu")) {
                print("Found end UI at " + i);
                // add our button
                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'data-nav-targets="_;_;_;button-next-map;button-challenge;_;_"\n					data-nav-group="navgroup-endracemenu-default"\n					data-nav-zone="ComponentTrackmania_Button_quad-background"\n					data-menusounds-selectsound="IngameSelectStartRace"\n				/>', 'data-nav-targets="_;_;_;button-next-map;button-clip;_;_"\n					data-nav-group="navgroup-endracemenu-default"\n					data-nav-zone="ComponentTrackmania_Button_quad-background"\n					data-menusounds-selectsound="IngameSelectStartRace"\n				/>\n                <frameinstance\n					modelid="component-trackmania-button" id="button-clip"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="1"\n					data-opacityunfocus=".9"\n					data-size="125. 10.6952"\n					data-labelsize="90. 10.6952"\n					data-backgroundcolortype="0"\n					data-image="file://Media/Manialinks/Nadeo/TMGame/Menus/HUD_Campaign_Button_ObtuseCorner.dds"\n					data-imagefocus="file://Media/Manialinks/Nadeo/TMGame/Menus/HUD_Campaign_Button_ObtuseCorner_Focused.dds"\n					data-iconsize="7.69519 7.69519"\n					data-iconcolortype="0"\n					data-iconxpos=".9" data-iconypos="-.49"\n					data-text="Clip with Medal"\n					data-textopacityunfocus=".4"\n					data-textsize="4"\n					data-fitlabel="2."\n					data-textitalicslope=".2"\n					data-textfont="GameFontExtraBold"\n					data-textcolor="6EFAA0"\n					data-textfocuscolor="003228"\n					data-halign="center" data-valign="center"\n					data-nav-inputs="select;cancel;action2;up;down;pageup;pagedown"\n					data-nav-targets="_;_;_;button-improve;button-challenge;_;_"\n					data-nav-group="navgroup-endracemenu-default"\n					data-nav-zone="ComponentTrackmania_Button_quad-background"\n					data-menusounds-selectsound="IngameSelectStartRace"\n					hidden="0"\n				/>');

                // fix the offset this makes

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'modelid="component-trackmania-button" id="button-challenge"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="1"', 'modelid="component-trackmania-button" id="button-challenge"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="2"');
                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'data-nav-targets="_;_;_;button-improve;button-opponents;_;_"', 'data-nav-targets="_;_;_;button-clip;button-opponents;_;_"');

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'modelid="component-trackmania-button" id="button-opponents" z-index="1"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="2"', 'modelid="component-trackmania-button" id="button-opponents" z-index="1"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="3"');

                Layer.ManialinkPage  = Regex::Replace(Layer.ManialinkPage, 'modelid="component-trackmania-button" id="button-replay" z-index="2"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="3"', 'modelid="component-trackmania-button" id="button-replay" z-index="2"\n					class="component-navigation-item component-menusounds-item component-grid-element"\n					data-grid-row="4"');

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'Trackmania_Button::SetVisibilityAndNavigation(_State.Controls.Button_Challenge, _State.MedalghostVisibility);', 'Trackmania_Button::SetVisibilityAndNavigation(_State.Controls.Button_Challenge, _State.MedalghostVisibility);\n	Trackmania_Button::SetVisibilityAndNavigation(_State.Controls.Button_Clip, True);');

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'Button_Improve = (Frame_Global.GetFirstChild("button-improve") as CMlFrame),', 'Button_Improve = (Frame_Global.GetFirstChild("button-improve") as CMlFrame),\n		Button_Clip = (Frame_Global.GetFirstChild("button-clip") as CMlFrame),');

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, 'CMlFrame Button_Improve;', 'CMlFrame Button_Improve;\n	CMlFrame Button_Clip;');

                // add an event to be invoked when our button is clicked
                string before = 'case "button-improve": SendCustomEvent("EndRaceMenuEvent_Improve", []);';
                string after = 'case "button-resume": CloseInGameMenu(CMlScriptIngame::EInGameMenuResult::Resume);\n		case "button-clip": {\n			SendCustomEvent("RaceMenuEvent_InvokeMedalClip", []);\n			CloseInGameMenu(CMlScriptIngame::EInGameMenuResult::Resume);\n		}';
                before = EscapeRegex(before);

                Layer.ManialinkPage = Regex::Replace(Layer.ManialinkPage, before, after);

                break;
            }
        }
    } else
        warn("CMAP error");
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
bool isPlayerAFK = false;
uint AFKTimeMS  = 0;

// watches the checkpoints to see if we've crossed any of them
void Intercept() {
    if (intercepting) {
        warn("Intercept called, but it's already running!");
        return;
    }

    if (GetApp().CurrentPlayground is null)
        return;

    trace("Medal started intercepting checkpoint events");

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
            trace("Hit checkpoint #" + checkpoints + " at " + minutes + ":" + seconds + "." + milliseconds);
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

string EscapeRegex(string s) {
	return s
		.Replace(".", "\\.")
		.Replace("(", "\\(")
		.Replace(")", "\\)")
		.Replace("[", "\\[")
		.Replace("]", "\\]")
		.Replace("{", "\\{")
		.Replace("}", "\\}");
}

// when script is closed make sure to remove any hooks we left
void OnDestroyed() { _Unload(); }
void OnDisabled() { _Unload(); }
void _Unload() {
    trace('_Unload, unloading all hooks and removing all injected ML');
    MLHook::UnregisterMLHooksAndRemoveInjectedML();
}
