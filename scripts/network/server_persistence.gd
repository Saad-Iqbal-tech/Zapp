class_name ServerPersistence
extends RefCounted
## Server-side persistent storage for player accounts, unique usernames,
## match statistics (wins, losses, draws, matches played, eliminations),
## match history, and the global leaderboard.
## All stat updates are server-validated from authoritative ServerMatchSession outcomes.

const DEFAULT_SAVE_PATH: String = "user://server_persistence.json"
const MAX_PLAYER_HISTORY: int = 15
const MAX_GLOBAL_HISTORY: int = 50

var save_path: String = DEFAULT_SAVE_PATH

# username (String) -> {
#   "username": String,
#   "token_hash": String,
#   "wins": int,
#   "losses": int,
#   "draws": int,
#   "matches_played": int,
#   "eliminations": int,
#   "match_history": Array[Dictionary]
# }
var accounts: Dictionary = {}
var global_match_history: Array[Dictionary] = []
var last_load_error: String = ""
var _recorded_session_ids: Dictionary = {}


func _init(custom_save_path: String = DEFAULT_SAVE_PATH) -> void:
	save_path = custom_save_path
	load_from_disk()


func load_from_disk() -> bool:
	last_load_error = ""
	if save_path.is_empty():
		return false

	var primary_exists := FileAccess.file_exists(save_path)
	var bak_path := save_path + ".bak"
	var bak_exists := FileAccess.file_exists(bak_path)
	if not primary_exists and not bak_exists:
		return true

	if primary_exists and _try_load_file(save_path):
		return true

	# Primary file was corrupted or unreadable; record error and attempt backup recovery
	if last_load_error.is_empty():
		last_load_error = "Failed to load persistence file: %s" % save_path
	push_warning("[ServerPersistence] %s" % last_load_error)

	if bak_exists and _try_load_file(bak_path):
		push_warning("[ServerPersistence] Recovered persistence state from backup: %s" % bak_path)
		return true

	return false


func _try_load_file(path_to_read: String) -> bool:
	var f := FileAccess.open(path_to_read, FileAccess.READ)
	if not f:
		last_load_error = "Could not open file for reading: %s" % path_to_read
		return false
	var text := f.get_as_text()
	f.close()
	if text.strip_edges().is_empty():
		last_load_error = "Persistence file is empty: %s" % path_to_read
		return false

	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		last_load_error = "Invalid JSON in %s (line %d: %s)" % [path_to_read, json.get_error_line(), json.get_error_message()]
		return false

	var data: Dictionary = json.data
	if not data.has("accounts") or typeof(data["accounts"]) != TYPE_DICTIONARY:
		last_load_error = "Missing or invalid 'accounts' dictionary in %s" % path_to_read
		return false

	var clean_accounts: Dictionary = {}
	var raw_accounts: Dictionary = data["accounts"]
	for raw_key in raw_accounts.keys():
		var entry: Variant = raw_accounts[raw_key]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var acc_dict: Dictionary = entry
		var uname := NetProtocol.sanitize_player_name(str(acc_dict.get("username", raw_key)), "")
		if uname.is_empty():
			continue
		var clean_hist: Array[Dictionary] = []
		if acc_dict.has("match_history") and typeof(acc_dict["match_history"]) == TYPE_ARRAY:
			for h_item in acc_dict["match_history"]:
				if typeof(h_item) == TYPE_DICTIONARY:
					clean_hist.append(h_item)
		clean_accounts[uname] = {
			"username": uname,
			"token_hash": str(acc_dict.get("token_hash", "")),
			"wins": maxi(0, int(acc_dict.get("wins", 0))),
			"losses": maxi(0, int(acc_dict.get("losses", 0))),
			"draws": maxi(0, int(acc_dict.get("draws", 0))),
			"matches_played": maxi(0, int(acc_dict.get("matches_played", 0))),
			"eliminations": maxi(0, int(acc_dict.get("eliminations", 0))),
			"match_history": clean_hist
		}

	accounts = clean_accounts
	global_match_history.clear()
	_recorded_session_ids.clear()
	if data.has("global_match_history") and typeof(data["global_match_history"]) == TYPE_ARRAY:
		for item in data["global_match_history"]:
			if typeof(item) == TYPE_DICTIONARY:
				global_match_history.append(item)
				var sid := str(item.get("session_id", ""))
				if not sid.is_empty():
					_recorded_session_ids[sid] = true
	return true


func save_to_disk() -> bool:
	if save_path.is_empty():
		return false

	var payload := {
		"version": 1,
		"accounts": accounts,
		"global_match_history": global_match_history
	}
	var json_str := JSON.stringify(payload, "\t")
	if json_str.is_empty():
		return false

	var tmp_path := save_path + ".tmp"
	var bak_path := save_path + ".bak"

	var f_tmp := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not f_tmp:
		return false
	f_tmp.store_string(json_str)
	f_tmp.flush()
	f_tmp.close()

	var abs_save := ProjectSettings.globalize_path(save_path)
	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_bak := ProjectSettings.globalize_path(bak_path)

	# Keep a backup of the previous valid file before replacing
	if FileAccess.file_exists(save_path):
		var f_old := FileAccess.open(save_path, FileAccess.READ)
		if f_old:
			var old_txt := f_old.get_as_text()
			f_old.close()
			if not old_txt.strip_edges().is_empty():
				var f_bak := FileAccess.open(bak_path, FileAccess.WRITE)
				if f_bak:
					f_bak.store_string(old_txt)
					f_bak.flush()
					f_bak.close()

	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(abs_save)
	var ren_err := DirAccess.rename_absolute(abs_tmp, abs_save)
	if ren_err != OK:
		# Fallback direct write if rename across virtual mount fails
		var f_direct := FileAccess.open(save_path, FileAccess.WRITE)
		if not f_direct:
			return false
		f_direct.store_string(json_str)
		f_direct.flush()
		f_direct.close()
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(abs_tmp)
	return true


## Registers a new username or authenticates an existing username via secret client token.
## If the requested username is already owned by a different token, assigns a unique suffix
## so another client cannot impersonate or overwrite an existing player's account.
func authenticate_or_register_player(
	requested_name: String,
	raw_token: String,
	fallback_peer_id: int
) -> Dictionary:
	var base_name := NetProtocol.sanitize_player_name(requested_name, "P_%d" % fallback_peer_id)
	var token_clean := raw_token.strip_edges()
	if token_clean.is_empty():
		token_clean = "anon_peer_%d" % fallback_peer_id
	var token_hash := token_clean.sha256_text()

	var resolved_name := base_name
	if accounts.has(base_name):
		var existing: Dictionary = accounts[base_name]
		if str(existing.get("token_hash", "")) == token_hash:
			# Returning owner of this username
			return get_public_profile(base_name)
		else:
			# Username belongs to another token — find an available unique suffix
			var suffix := 2
			while suffix < 1000:
				var candidate := "%s_%d" % [base_name.left(12), suffix]
				if not accounts.has(candidate):
					resolved_name = candidate
					break
				elif str(accounts[candidate].get("token_hash", "")) == token_hash:
					resolved_name = candidate
					return get_public_profile(resolved_name)
				suffix += 1

	accounts[resolved_name] = {
		"username": resolved_name,
		"token_hash": token_hash,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"matches_played": 0,
		"eliminations": 0,
		"match_history": []
	}
	save_to_disk()
	return get_public_profile(resolved_name)


func get_public_profile(username: String) -> Dictionary:
	if not accounts.has(username):
		return {
			"username": username,
			"wins": 0,
			"losses": 0,
			"draws": 0,
			"matches_played": 0,
			"eliminations": 0,
			"match_history": []
		}
	var acc: Dictionary = accounts[username]
	return {
		"username": str(acc.get("username", username)),
		"wins": int(acc.get("wins", 0)),
		"losses": int(acc.get("losses", 0)),
		"draws": int(acc.get("draws", 0)),
		"matches_played": int(acc.get("matches_played", 0)),
		"eliminations": int(acc.get("eliminations", 0)),
		"match_history": (acc.get("match_history", []) as Array).duplicate(true)
	}


## Updates player statistics exclusively from an authoritative ServerMatchSession summary.
## Returns true if recorded, or false if rejected (e.g. duplicate session_id or invalid summary).
func record_authoritative_match(summary: Dictionary) -> bool:
	var session_id := str(summary.get("session_id", "")).strip_edges()
	if session_id.is_empty() or _recorded_session_ids.has(session_id):
		return false

	var slots: Array = summary.get("slots", []) if typeof(summary.get("slots", [])) == TYPE_ARRAY else []
	var active_count := 0
	for s in slots:
		if typeof(s) == TYPE_DICTIONARY and bool(s.get("active", false)):
			active_count += 1
	if active_count < 2:
		return false

	_recorded_session_ids[session_id] = true
	var is_draw := bool(summary.get("is_draw", false))
	var winner_slot := int(summary.get("winner_slot_id", -1))
	var winner_name := str(summary.get("winner_name", "NONE" if is_draw else "UNKNOWN"))
	var rounds := maxi(1, int(summary.get("rounds_completed", 1)))
	var final_stage := clampi(int(summary.get("final_stage", 1)), 1, 4)
	var timestamp := Time.get_datetime_string_from_system(true)

	var participant_names: Array[String] = []
	var updated_usernames: Dictionary = {}

	for s in slots:
		if typeof(s) != TYPE_DICTIONARY or not bool(s.get("active", false)):
			continue
		var p_name := str(s.get("name", ""))
		participant_names.append(p_name)

		if not bool(s.get("is_human", false)) or p_name.is_empty():
			continue
		# Guard against recording the same username twice in a single match summary
		if updated_usernames.has(p_name):
			continue
		updated_usernames[p_name] = true

		if not accounts.has(p_name):
			accounts[p_name] = {
				"username": p_name,
				"token_hash": "",
				"wins": 0,
				"losses": 0,
				"draws": 0,
				"matches_played": 0,
				"eliminations": 0,
				"match_history": []
			}

		var acc: Dictionary = accounts[p_name]
		var slot_id := int(s.get("slot_id", -1))
		var elims := maxi(0, int(s.get("eliminations", 0)))

		acc["matches_played"] = int(acc.get("matches_played", 0)) + 1
		acc["eliminations"] = int(acc.get("eliminations", 0)) + elims

		var outcome := "LOSS"
		if is_draw:
			acc["draws"] = int(acc.get("draws", 0)) + 1
			outcome = "DRAW"
		elif slot_id == winner_slot:
			acc["wins"] = int(acc.get("wins", 0)) + 1
			outcome = "WIN"
		else:
			acc["losses"] = int(acc.get("losses", 0)) + 1
			outcome = "LOSS"

		var p_hist: Array = acc.get("match_history", [])
		p_hist.push_front({
			"session_id": session_id,
			"timestamp": timestamp,
			"outcome": outcome,
			"winner_name": winner_name,
			"eliminations": elims,
			"rounds": rounds,
			"final_stage": final_stage
		})
		while p_hist.size() > MAX_PLAYER_HISTORY:
			p_hist.pop_back()
		acc["match_history"] = p_hist

	global_match_history.push_front({
		"session_id": session_id,
		"timestamp": timestamp,
		"is_draw": is_draw,
		"winner_name": winner_name,
		"rounds": rounds,
		"final_stage": final_stage,
		"participants": participant_names
	})
	while global_match_history.size() > MAX_GLOBAL_HISTORY:
		global_match_history.pop_back()

	save_to_disk()
	return true


func get_leaderboard(limit: int = 20) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for uname in accounts.keys():
		var acc: Dictionary = accounts[uname]
		var mp := int(acc.get("matches_played", 0))
		var wins := int(acc.get("wins", 0))
		var losses := int(acc.get("losses", 0))
		var draws := int(acc.get("draws", 0))
		var elims := int(acc.get("eliminations", 0))
		rows.append({
			"username": str(acc.get("username", uname)),
			"wins": wins,
			"losses": losses,
			"draws": draws,
			"matches_played": mp,
			"eliminations": elims
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["wins"]) != int(b["wins"]):
			return int(a["wins"]) > int(b["wins"])
		if int(a["eliminations"]) != int(b["eliminations"]):
			return int(a["eliminations"]) > int(b["eliminations"])
		return int(a["matches_played"]) > int(b["matches_played"])
	)

	var out: Array[Dictionary] = []
	for i in range(mini(limit, rows.size())):
		var r := rows[i].duplicate()
		r["rank"] = i + 1
		out.append(r)
	return out
